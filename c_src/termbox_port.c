#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h> // For getpid(), unlink(), isatty(), read(), write()
#include <termios.h> // Add this include
#include <sys/socket.h> // For socket programming
#include <sys/un.h>     // For Unix domain sockets
#include <errno.h>      // For error numbers
#include <sys/types.h>  // For pid_t
#include <stdint.h>    // For uint16_t
#include <arpa/inet.h> // For htons, ntohs
#include <sys/select.h> // For select()
#include <fcntl.h>      // For fcntl, F_GETFL, O_NONBLOCK
// Remove select/time/errno includes
#include "termbox.h" // Assuming termbox.h is accessible

#define MAX_LINE_LENGTH 4096
#define MAX_ARGS 10
#define SOCKET_PATH_TEMPLATE "/tmp/termbox_port_%d.sock"
// #define SOCKET_PATH_HARDCODED "/tmp/termbox_test.sock"
#define SOCKET_BUFFER_SIZE 4096 // For reading from socket
#define MAX_EVENT_STR_SIZE 256 // Max size for formatted event string

// Global variable for the connected client socket
int client_socket_fd = -1;
char actual_socket_path[256]; // ADD BACK - Store dynamic path
// const char *actual_socket_path = SOCKET_PATH_HARDCODED; // REMOVE - Use constant pointer

// --- Shadow Buffer Globals ---
struct tb_cell *shadow_buffer = NULL;
int shadow_buffer_width = 0;
int shadow_buffer_height = 0;
// --- End Shadow Buffer Globals ---

// Function to send a response back to Elixir - Comment out
// void send_response(const char *response) { ... }

// Function to send an error response - Comment out
// void send_error(const char *reason) { ... }

// Function to send an OK response (potentially with data) - Comment out
// void send_ok(const char *data) { ... }

// Forward declarations for helper functions
ssize_t write_exact(int fd, const void *buf, size_t count);
ssize_t write_socket_line(int fd, const char *line);
void log_message(const char* msg);
int run_main_loop(int listen_fd); // Declare the main loop function
int handle_client_command(int client_fd, char* buffer, ssize_t len); // Declare command handler
void send_event_to_client(int client_fd, struct tb_event *ev); // Declare event sender
void update_shadow_buffer_size(int width, int height); // Declare shadow buffer function

// --- Helper function to write exactly n bytes ---
ssize_t write_exact(int fd, const void *buf, size_t count) {
    size_t bytes_written = 0;
    while (bytes_written < count) {
        ssize_t result = write(fd, (const char*)buf + bytes_written, count - bytes_written);
        if (result < 0) {
            if (errno == EINTR) continue; // Interrupted by signal, try again
            return -1; // Write error
        }
        // write() returning 0 usually means error, but we check result < 0 first
        bytes_written += result;
    }
    return bytes_written;
}

// --- Helper function to write a complete newline-terminated string to socket ---
ssize_t write_socket_line(int fd, const char *line) {
    size_t len = strlen(line);
    if (len == 0) return 0; // Nothing to write

    char buffer[len + 2]; // +1 for newline, +1 for null terminator
    memcpy(buffer, line, len);
    buffer[len] = '\n';
    buffer[len + 1] = '\0';

    // Use write_exact to ensure the full line + newline is sent
    return write_exact(fd, buffer, len + 1);
}

// --- Logging function writes to stderr ---
void log_message(const char* msg) {
    // Log to stderr to keep stdout clean for socket path/initial ok
    // fprintf(stderr, "termbox_port C_LOG: %s\n", msg);
    // fflush(stderr);
}

// --- Shadow Buffer Management ---
void update_shadow_buffer_size(int width, int height) {
    char log_buf[100];
    snprintf(log_buf, sizeof(log_buf), "Updating shadow buffer size: %d x %d", width, height);
    // log_message(log_buf);

    if (shadow_buffer != NULL) {
        free(shadow_buffer);
        shadow_buffer = NULL;
    }

    shadow_buffer_width = width;
    shadow_buffer_height = height;

    if (width <= 0 || height <= 0) {
        // log_message("Invalid dimensions for shadow buffer, setting to NULL.");
        shadow_buffer_width = 0;
        shadow_buffer_height = 0;
        return;
    }

    size_t buffer_size = (size_t)width * height * sizeof(struct tb_cell);
    shadow_buffer = (struct tb_cell*)malloc(buffer_size);

    if (shadow_buffer == NULL) {
        snprintf(log_buf, sizeof(log_buf), "Error: Failed to allocate shadow buffer (%zu bytes).", buffer_size);
        fprintf(stderr, "termbox_port C_LOG ERROR: %s\n", log_buf); // Keep error log
        fflush(stderr);
        // log_message(log_buf); // Redundant
        shadow_buffer_width = 0;
        shadow_buffer_height = 0;
        // Consider exiting or signaling critical error? For now, just log.
    } else {
        // log_message("Shadow buffer allocated. Initializing cells...");
        // Initialize cells (e.g., space char, default colors)
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                size_t index = (size_t)y * width + x;
                shadow_buffer[index].ch = ' '; // Use space as default char
                shadow_buffer[index].fg = TB_DEFAULT; // Use default fg
                shadow_buffer[index].bg = TB_DEFAULT; // Use default bg
            }
        }
        // log_message("Shadow buffer initialized.");
    }
}
// --- End Shadow Buffer Management ---

int main() {
    // Keep stderr unbuffered for logs
    setbuf(stderr, NULL);

    // log_message("Port process starting up (UDS PATH VIA STDOUT MODE)."); // Keep startup
    fprintf(stderr, "termbox_port C_LOG: Port process starting up (UDS PATH VIA STDOUT MODE).\n");
    fflush(stderr);

    // --- NO LONGER NEED TO READ FROM STDIN --- 
    // log_message("Skipping stdin read for trigger. Will send path directly.");
    // --- END STDIN READ REMOVAL ---


    // --- UDS Socket Setup ---
    int listen_socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_socket_fd == -1) {
        perror("Error creating listen socket");
        // log_message("Error: Failed to create UDS listen socket."); // Keep perror
        fprintf(stderr, "error socket_create_failed\n");
        return 1;
    }
    // log_message("UDS listen socket created.");

    struct sockaddr_un server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sun_family = AF_UNIX;
    // Use a path within the project structure (relative to where port is run)
    // Assuming CWD is project root, place it in _build
    // snprintf(actual_socket_path, sizeof(actual_socket_path), "_build/termbox_port_%d.sock", getpid());
    // Use absolute path in /tmp
    snprintf(actual_socket_path, sizeof(actual_socket_path), SOCKET_PATH_TEMPLATE, getpid());

    // Remove existing socket file if it exists
    unlink(actual_socket_path); // Use the char array directly

    strncpy(server_addr.sun_path, actual_socket_path, sizeof(server_addr.sun_path) - 1); // Use the char array directly

    // log_message("Attempting to bind socket to path:");
    // fprintf(stderr, "termbox_port C_LOG: Attempting to bind UDS to path: %s\n", actual_socket_path); // ADD path log
    // fflush(stderr);
    // log_message(actual_socket_path); // Log the hardcoded path REMOVE

    if (bind(listen_socket_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) == -1) {
        perror("Error binding socket");
        // log_message("Error: Failed to bind UDS socket."); // Keep perror
        close(listen_socket_fd);
        unlink(actual_socket_path); // Clean up (uses the absolute path now)
        fprintf(stderr, "error socket_bind_failed\n");
        return 1;
    }

    if (listen(listen_socket_fd, 5) == -1) {
        perror("Error listening on socket");
        // log_message("Error: Failed to listen on UDS socket."); // Keep perror
        close(listen_socket_fd);
        unlink(actual_socket_path); // Clean up (uses the absolute path now)
        fprintf(stderr, "error socket_listen_failed\n");
        return 1;
    }

    fprintf(stdout, "OK %s\n", actual_socket_path); // Send the dynamic path back
    fflush(stdout); // IMPORTANT: Flush stdout!

    // --- END UDS Socket Setup (Termbox init removed) ---


    // --- Accept connection and run main loop (existing logic) ---
    // log_message("Waiting for client connection on UDS...");
    // This will block until Elixir connects via :gen_unix
    int result = run_main_loop(listen_socket_fd);
    // --- END Accept connection and run main loop ---


    // Clean up termbox before exiting (already present in run_main_loop or after)
    // log_message("Port process exiting."); // Keep exit
    fprintf(stderr, "termbox_port C_LOG: Port process exiting.\n");
    fflush(stderr);
    return result == 0 ? 0 : 1; // Return 0 on success, 1 on error from loop
}

// --- Main UDS Communication Loop ---
int run_main_loop(int listen_fd) {
    // log_message("Entering main loop. Waiting for client connection...");
    fprintf(stderr, "termbox_port C_LOG: Entering main loop. Waiting for client connection on fd %d at path %s...\n", listen_fd, actual_socket_path);
    fflush(stderr);

    // Accept the client connection (blocking)
    struct sockaddr_un client_addr;
    socklen_t client_addr_len = sizeof(client_addr);
    client_socket_fd = accept(listen_fd, (struct sockaddr*)&client_addr, &client_addr_len);

    if (client_socket_fd == -1) {
        perror("Error accepting client connection");
        fprintf(stderr, "termbox_port C_LOG ERROR: Failed to accept UDS connection.\n");
        fflush(stderr);
        return 1; // Indicate error
    }
    fprintf(stderr, "termbox_port C_LOG: Client connected successfully.\n");
    fflush(stderr);

    // --- Initialize Termbox MOVED TO CMD_INIT handler ---
    // log_message("Initializing Termbox post-accept...");
    // int tb_ret = tb_init();
    // if (tb_ret != 0) {
    //     char err_msg[100];
    //     snprintf(err_msg, sizeof(err_msg), "tb_init() failed post-accept with code: %d", tb_ret);
    //     fprintf(stderr, "termbox_port C_LOG ERROR: %s\n", err_msg);
    //     fflush(stderr);
    //     write_socket_line(client_socket_fd, "ERROR tb_init_failed");
    //     close(client_socket_fd);
    //     client_socket_fd = -1;
    //     return 1; // Error
    // }
    // fprintf(stderr, "termbox_port C_LOG: Termbox initialized successfully (MOVED TO CMD_INIT).\n");
    // fflush(stderr);
    // update_shadow_buffer_size(tb_width(), tb_height()); // Also moved
    // --- End Termbox Initialization ---

    // Set client socket to non-blocking
    int flags = fcntl(client_socket_fd, F_GETFL, 0);
    if (flags == -1) {
        perror("Error getting socket flags");
        close(client_socket_fd);
        client_socket_fd = -1;
        return 1; // Indicate error
    }
    if (fcntl(client_socket_fd, F_SETFL, flags | O_NONBLOCK) == -1) {
        perror("Error setting socket to non-blocking");
        close(client_socket_fd);
        client_socket_fd = -1;
        return 1; // Indicate error
    }

    // --- Main event/command loop ---
    fd_set read_fds;
    char socket_buffer[SOCKET_BUFFER_SIZE];
    ssize_t bytes_read;
    size_t buffer_pos = 0; // Current position in the buffer
    bool keep_running = true;
    int loop_exit_status = 1; // Default to error unless shutdown command received

    while (keep_running) { // Loop until shutdown command or error
        // 1. Check for termbox events with a short, non-blocking peek
        struct tb_event event;
        int peek_ret = tb_peek_event(&event, 10); // 10 ms timeout
        if (peek_ret > 0) {
            // log_message("Termbox event received via peek, processing...");
            
            // --- Handle Resize Event Internally FIRST ---
            if (event.type == TB_EVENT_RESIZE) {
                 char resize_log[100];
                 snprintf(resize_log, sizeof(resize_log), "Resize event detected: %d x %d. Updating shadow buffer...", event.w, event.h);
                 // log_message(resize_log);
                 update_shadow_buffer_size(event.w, event.h);
                 // Note: tb_clear() might be implicitly called by termbox on resize,
                 // or we might need to call it explicitly if the screen content becomes garbage.
                 // If we call tb_clear(), we should also update the shadow buffer accordingly.
                 // For now, just update size based on event.
            }
            // --- End Handle Resize Event ---

            // log_message("Sending event to client.");
            send_event_to_client(client_socket_fd, &event);
        } else if (peek_ret < 0) {
            // log_message("tb_peek_event returned error/negative. Potential resize or other issue?");
        }

        // 2. Check client socket for commands using select() with zero timeout
        FD_ZERO(&read_fds);
        FD_SET(client_socket_fd, &read_fds);
        int max_fd = client_socket_fd;
        struct timeval select_timeout;
        select_timeout.tv_sec = 0;
        select_timeout.tv_usec = 0;
        int activity = select(max_fd + 1, &read_fds, NULL, NULL, &select_timeout);

        if (activity < 0) {
            if (errno == EINTR) continue;
            perror("select() error");
            // log_message("Error: select() failed."); // Keep perror
            keep_running = false;
            loop_exit_status = 1; // Error exit
        } else if (activity == 0) {
            continue; // No data on socket, loop to peek termbox again
        }

        // 3. If socket is ready, read and process data
        if (FD_ISSET(client_socket_fd, &read_fds)) {
            bytes_read = read(client_socket_fd,
                              socket_buffer + buffer_pos,
                              SOCKET_BUFFER_SIZE - 1 - buffer_pos);

            if (bytes_read < 0) {
                if (errno == EINTR) continue;
                perror("read() error from client socket");
                log_message("Error: Failed reading from client socket.");
                keep_running = false;
                loop_exit_status = 1; // Error exit
            } else if (bytes_read == 0) {
                log_message("Client closed the connection.");
                keep_running = false;
                loop_exit_status = 0; // Treat client close as non-error exit for now
            } else {
                buffer_pos += bytes_read;
                socket_buffer[buffer_pos] = '\0';

                char *line_start = socket_buffer;
                char *newline_pos;
                while ((newline_pos = strchr(line_start, '\n')) != NULL) {
                    *newline_pos = '\0';
                    ssize_t line_len = newline_pos - line_start;

                    int cmd_result = handle_client_command(client_socket_fd, line_start, line_len);

                    if (cmd_result == 1) {
                        log_message("Shutdown command processed in loop.");
                        keep_running = false;
                        loop_exit_status = 0; // Clean shutdown exit
                        break;
                    } else if (cmd_result < 0) {
                        log_message("Error reported by handle_client_command. Exiting loop.");
                        keep_running = false;
                        loop_exit_status = 1; // Error exit
                        break;
                    }

                    line_start = newline_pos + 1;
                }

                if (!keep_running) break;

                if (line_start < socket_buffer + buffer_pos) {
                    size_t remaining_len = buffer_pos - (line_start - socket_buffer);
                    memmove(socket_buffer, line_start, remaining_len);
                    buffer_pos = remaining_len;
                } else {
                    buffer_pos = 0;
                }

                if (buffer_pos >= SOCKET_BUFFER_SIZE - 1) {
                    log_message("Error: Socket receive buffer overflow after processing.");
                    buffer_pos = 0;
                }
            }
        }
    }

    // --- Clean up Termbox and client socket before exiting loop ---
    log_message("Shutting down Termbox...");
    tb_shutdown();
    log_message("Closing client socket...");
    if (client_socket_fd != -1) {
        close(client_socket_fd);
        client_socket_fd = -1;
    }
    log_message("Exiting main loop.");
    return loop_exit_status;
}

// --- Helper function to handle a single command line from the client ---
// Returns 0 on success, 1 on error/exit condition.
int handle_client_command(int client_fd, char* command_line, ssize_t len) {
    // Nul-terminate the received command line in place
    // (Assumes buffer has space or len accounts for it)
    if (len > 0 && len < SOCKET_BUFFER_SIZE) {
        command_line[len] = '\0';
    }

    // Remove trailing newline/CR if present
    if (len > 0 && command_line[len - 1] == '\n') {
        command_line[len - 1] = '\0';
        len--;
    }
    if (len > 0 && command_line[len - 1] == '\r') {
        command_line[len - 1] = '\0';
        len--;
    }

    char log_buf[SOCKET_BUFFER_SIZE + 50]; // Buffer for logging
    snprintf(log_buf, sizeof(log_buf), "Received command: '%s' (len: %zd)", command_line, len);
    log_message(log_buf);

    // Simple command parsing (split by space)
    char *args[MAX_ARGS];
    int argc = 0;
    char *token = strtok(command_line, " ");
    while (token != NULL && argc < MAX_ARGS) {
        args[argc++] = token;
        token = strtok(NULL, " ");
    }

    if (argc == 0) {
        log_message("Empty command received.");
        return 0; // Ignore empty commands
    }

    const char *cmd = args[0];

    // Compare command
    if (strcmp(cmd, "present") == 0) {
        if (argc == 1) {
            // log_message("Executing tb_present()...");
            tb_present();
            // log_message("tb_present() done.");
            if (write_socket_line(client_fd, "OK") < 0) {
                perror("Error writing OK response for present");
                return 1; // Indicate write error
            }
        } else {
            log_message("Error: 'present' command expects 0 arguments.");
            write_socket_line(client_fd, "ERROR invalid_args_present");
        }
    } else if (strcmp(cmd, "clear") == 0) {
        if (argc == 1) {
            tb_clear();
            // --- Shadow Buffer Update for clear ---
            if (shadow_buffer && shadow_buffer_width > 0 && shadow_buffer_height > 0) {
                log_message("Clearing shadow buffer...");
                for (int y = 0; y < shadow_buffer_height; ++y) {
                    for (int x = 0; x < shadow_buffer_width; ++x) {
                        size_t index = (size_t)y * shadow_buffer_width + x;
                        shadow_buffer[index].ch = ' '; // Clear with space
                        shadow_buffer[index].fg = TB_DEFAULT;
                        shadow_buffer[index].bg = TB_DEFAULT;
                    }
                }
                log_message("Shadow buffer cleared.");
            }
            // --- End Shadow Buffer Update for clear ---
            if (write_socket_line(client_fd, "OK") < 0) {
                perror("Error writing OK response for clear");
                return 1;
            }
        } else {
            log_message("Error: 'clear' command expects 0 arguments.");
            write_socket_line(client_fd, "ERROR invalid_args_clear");
        }
    } else if (strcmp(cmd, "print") == 0) {
        // print x y fg bg text...
        if (argc >= 6) {
            int x = atoi(args[1]);
            int y = atoi(args[2]);
            uint16_t fg = (uint16_t)atoi(args[3]);
            uint16_t bg = (uint16_t)atoi(args[4]);

            // Reconstruct the text part (everything from args[5] onwards)
            char text_buffer[SOCKET_BUFFER_SIZE] = {0};
            char *current_ptr = text_buffer;
            for (int i = 5; i < argc; ++i) {
                size_t arg_len = strlen(args[i]);
                // Check buffer overflow potential
                if (current_ptr + arg_len + (i > 5 ? 1 : 0) - text_buffer >= SOCKET_BUFFER_SIZE) {
                    log_message("Error: 'print' command text exceeds buffer.");
                    write_socket_line(client_fd, "ERROR text_too_long_print");
                    return 0; // Handled error, don't signal loop exit
                }
                if (i > 5) {
                    *current_ptr++ = ' '; // Add space between args
                }
                strcpy(current_ptr, args[i]);
                current_ptr += arg_len;
            }

            // --- Use tb_print for simplicity (uses tb_change_cell internally) ---
            // tb_print(x, y, fg, bg, text_buffer);
            // Let's simulate tb_print using tb_change_cell to update shadow buffer
            char *text_ptr = text_buffer;
            uint32_t codepoint;
            int current_x = x;
            log_message("Executing print (via change_cell loop)...");
            while (*text_ptr != '\0') {
                // Decode UTF-8 character
                text_ptr += tb_utf8_char_to_unicode(&codepoint, text_ptr);
                if (codepoint == 0) break; // End of string or error

                // Call tb_change_cell for each character
                tb_change_cell(current_x, y, codepoint, fg, bg);

                // --- Shadow Buffer Update for print (via change_cell) ---
                if (shadow_buffer && current_x >= 0 && current_x < shadow_buffer_width && y >= 0 && y < shadow_buffer_height) {
                    size_t index = (size_t)y * shadow_buffer_width + current_x;
                    shadow_buffer[index].ch = codepoint;
                    shadow_buffer[index].fg = fg;
                    shadow_buffer[index].bg = bg;
                }
                // --- End Shadow Buffer Update ---

                current_x++; // Move to the next column
            }
            log_message("Print loop finished.");

            if (write_socket_line(client_fd, "OK") < 0) {
                perror("Error writing OK response for print");
                return 1;
            }
        } else {
            log_message("Error: 'print' command expects at least 5 arguments (x y fg bg text).");
            write_socket_line(client_fd, "ERROR invalid_args_print");
        }
    } else if (strcmp(cmd, "change_cell") == 0) {
        if (argc == 6) {
            int x = atoi(args[1]);
            int y = atoi(args[2]);
            uint32_t codepoint = (uint32_t)strtoul(args[3], NULL, 10); // Use strtoul for uint32_t
            uint16_t fg = (uint16_t)atoi(args[4]);
            uint16_t bg = (uint16_t)atoi(args[5]);

            tb_change_cell(x, y, codepoint, fg, bg);

            // --- Shadow Buffer Update for change_cell ---
            if (shadow_buffer && x >= 0 && x < shadow_buffer_width && y >= 0 && y < shadow_buffer_height) {
                size_t index = (size_t)y * shadow_buffer_width + x;
                shadow_buffer[index].ch = codepoint;
                shadow_buffer[index].fg = fg;
                shadow_buffer[index].bg = bg;
                // snprintf(log_buf, sizeof(log_buf), "Shadow buffer updated at (%d, %d)", x, y);
                // log_message(log_buf);
            }
            // --- End Shadow Buffer Update ---

            if (write_socket_line(client_fd, "OK") < 0) {
                perror("Error writing OK response for change_cell");
                return 1;
            }
        } else {
            log_message("Error: 'change_cell' command expects 5 arguments (x y char fg bg).");
            write_socket_line(client_fd, "ERROR invalid_args_change_cell");
        }
    } else if (strcmp(cmd, "get_cell") == 0) {
        if (argc == 3) {
            int x = atoi(args[1]);
            int y = atoi(args[2]);

            if (!shadow_buffer || x < 0 || x >= shadow_buffer_width || y < 0 || y >= shadow_buffer_height) {
                snprintf(log_buf, sizeof(log_buf), "Error: 'get_cell' request out of bounds (%d, %d) or buffer invalid.", x, y);
                log_message(log_buf);
                write_socket_line(client_fd, "ERROR invalid_coords_get_cell");
            } else {
                size_t index = (size_t)y * shadow_buffer_width + x;
                struct tb_cell cell_data = shadow_buffer[index];

                // Convert the uint32_t codepoint back to a UTF-8 string
                char utf8_buffer[8]; // Max 4 bytes for UTF-8 + null terminator should be enough
                int bytes_written = tb_utf8_unicode_to_char(utf8_buffer, cell_data.ch);
                if (bytes_written <= 0) {
                    // Handle error or invalid codepoint - send a replacement character?
                    strcpy(utf8_buffer, "?");
                }
                // Ensure null termination just in case
                utf8_buffer[sizeof(utf8_buffer) - 1] = '\0';

                // Format the response: OK_CELL <x> <y> <char_utf8> <fg_raw> <bg_raw>
                char response_buffer[256]; // Make sure it's large enough
                snprintf(response_buffer, sizeof(response_buffer),
                         "OK_CELL %d %d %s %u %u",
                         x, y, utf8_buffer, cell_data.fg, cell_data.bg);

                // snprintf(log_buf, sizeof(log_buf), "Sending cell data: %s", response_buffer);
                // log_message(log_buf);

                if (write_socket_line(client_fd, response_buffer) < 0) {
                    perror("Error writing OK_CELL response for get_cell");
                    return 1;
                }
            }
        } else {
            log_message("Error: 'get_cell' command expects 2 arguments (x y).");
            write_socket_line(client_fd, "ERROR invalid_args_get_cell");
        }
    } else if (strcmp(cmd, "width") == 0) {
        if (argc == 1) {
            int width = tb_width();
            char response_buffer[32];
            snprintf(response_buffer, sizeof(response_buffer), "OK_WIDTH %d", width);
            if (write_socket_line(client_fd, response_buffer) < 0) {
                perror("Error writing OK_WIDTH response");
                return 1;
            }
        } else {
            log_message("Error: 'width' command expects 0 arguments.");
            write_socket_line(client_fd, "ERROR invalid_args_width");
        }
    } else if (strcmp(cmd, "height") == 0) {
        if (argc == 1) {
            int height = tb_height();
            char response_buffer[32];
            snprintf(response_buffer, sizeof(response_buffer), "OK_HEIGHT %d", height);
            if (write_socket_line(client_fd, response_buffer) < 0) {
                perror("Error writing OK_HEIGHT response");
                return 1;
            }
        } else {
            log_message("Error: 'height' command expects 0 arguments.");
            write_socket_line(client_fd, "ERROR invalid_args_height");
        }
    } else if (strcmp(cmd, "set_cursor") == 0) {
        if (argc == 3) {
            int x = atoi(args[1]);
            int y = atoi(args[2]);
            tb_set_cursor(x, y);
            if (write_socket_line(client_fd, "OK") < 0) {
                perror("Error writing OK response for set_cursor");
                return 1;
            }
        } else {
            log_message("Error: 'set_cursor' command expects 2 arguments (x y).");
            write_socket_line(client_fd, "ERROR invalid_args_set_cursor");
        }
    } else if (strcmp(cmd, "set_input_mode") == 0) {
        if (argc == 2) {
            int mode = atoi(args[1]);
            int result = tb_select_input_mode(mode);
            if (result < 0) {
                 snprintf(log_buf, sizeof(log_buf), "Error: tb_select_input_mode(%d) failed with code %d.", mode, result);
                 log_message(log_buf);
                 // Send a specific error if needed, or just a generic one
                 write_socket_line(client_fd, "ERROR tb_select_input_mode_failed");
            } else {
                if (write_socket_line(client_fd, "OK") < 0) {
                    perror("Error writing OK response for set_input_mode");
                    return 1;
                }
            }
        } else {
            log_message("Error: 'set_input_mode' command expects 1 argument (mode).");
            write_socket_line(client_fd, "ERROR invalid_args_set_input_mode");
        }
    } else if (strcmp(cmd, "set_output_mode") == 0) {
        if (argc == 2) {
            int mode = atoi(args[1]);
            int result = tb_select_output_mode(mode);
            if (result < 0) {
                 snprintf(log_buf, sizeof(log_buf), "Error: tb_select_output_mode(%d) failed with code %d.", mode, result);
                 log_message(log_buf);
                 // Send a specific error if needed, or just a generic one
                 write_socket_line(client_fd, "ERROR tb_select_output_mode_failed");
            } else {
                if (write_socket_line(client_fd, "OK") < 0) {
                    perror("Error writing OK response for set_output_mode");
                    return 1;
                }
            }
        } else {
            log_message("Error: 'set_output_mode' command expects 1 argument (mode).");
            write_socket_line(client_fd, "ERROR invalid_args_set_output_mode");
        }
    } else if (strcmp(cmd, "set_clear_attributes") == 0) {
        if (argc == 3) {
            uint16_t fg = (uint16_t)atoi(args[1]);
            uint16_t bg = (uint16_t)atoi(args[2]);
            tb_set_clear_attributes(fg, bg);
            // Note: No direct termbox return value to check for failure here.
            if (write_socket_line(client_fd, "OK") < 0) {
                perror("Error writing OK response for set_clear_attributes");
                return 1;
            }
        } else {
            log_message("Error: 'set_clear_attributes' command expects 2 arguments (fg bg).");
            write_socket_line(client_fd, "ERROR invalid_args_set_clear_attributes");
        }
    } else if (strcmp(cmd, "DEBUG_SEND_EVENT") == 0) {
        // DEBUG_SEND_EVENT type mod key ch w h x y
        if (argc == 9) {
            struct tb_event debug_event;
            debug_event.type = (uint8_t)atoi(args[1]);
            debug_event.mod = (uint8_t)atoi(args[2]);
            debug_event.key = (uint16_t)atoi(args[3]);
            // Use strtoul for char code point (can be > 127)
            debug_event.ch = (uint32_t)strtoul(args[4], NULL, 10); 
            debug_event.w = atoi(args[5]);
            debug_event.h = atoi(args[6]);
            debug_event.x = atoi(args[7]);
            debug_event.y = atoi(args[8]);

            log_message("DEBUG: Sending synthetic event via DEBUG_SEND_EVENT command.");
            send_event_to_client(client_fd, &debug_event);

            // No explicit response needed for debug command, event is the "response"
            // Optional: Could send an OK back if desired for testing flow. Let's omit for now.
            // write_socket_line(client_fd, "OK"); 

        } else {
            log_message("Error: 'DEBUG_SEND_EVENT' command expects 8 arguments (type mod key ch w h x y).");
            write_socket_line(client_fd, "ERROR invalid_args_debug_send_event");
        }
    } else if (strcmp(cmd, "shutdown") == 0) {
        log_message("Shutdown command received. Acknowledging and preparing to exit loop.");
        write_socket_line(client_fd, "OK"); // Acknowledge shutdown request
        return 1; // Signal to exit the main loop
    } else {
        snprintf(log_buf, sizeof(log_buf), "Error: Unknown command '%s'", cmd);
        log_message(log_buf);
        write_socket_line(client_fd, "ERROR unknown_command");
    }

    return 0; // Indicate success, continue loop
}

// --- Format and send a termbox event to the client ---
void send_event_to_client(int client_fd, struct tb_event *ev) {
    char event_str[MAX_EVENT_STR_SIZE];
    // Simple JSON-like format. Ensure proper escaping if needed later.
    // Note: tb_event uses uint32_t for ch, uint16_t for key, uint8_t for mod/type
    // Consider edge cases like non-ASCII chars if using %c directly for ch
    snprintf(event_str, sizeof(event_str),
             "EVENT {\"type\":%u, \"mod\":%u, \"key\":%u, \"ch\":%u, \"w\":%d, \"h\":%d, \"x\":%d, \"y\":%d}",
             ev->type, ev->mod, ev->key, ev->ch, ev->w, ev->h, ev->x, ev->y);

    log_message("Formatted event string:");
    log_message(event_str);

    if (write_socket_line(client_fd, event_str) < 0) {
        perror("Error writing event to client socket");
        log_message("Error: Failed to send event to client.");
        // What to do here? If the client pipe is broken, the next select/read should fail.
        // For now, just log it.
    } else {
        log_message("Event sent to client successfully.");
    }
} 