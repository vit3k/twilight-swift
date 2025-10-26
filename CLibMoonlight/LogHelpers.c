#include "LogHelpers.h"
#include <stdio.h>
#include <stdarg.h>

// Swift function that will handle the formatted log message
extern void swiftLogHandler(const char* message);

// C callback function that formats variadic arguments and calls Swift
void logMessageCallback(const char* format, ...) {
    char buffer[2048];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    
    swiftLogHandler(buffer);
}

// Helper function to get the function pointer for Swift
void* getLogMessageCallbackPointer(void) {
    return (void*)logMessageCallback;
}
