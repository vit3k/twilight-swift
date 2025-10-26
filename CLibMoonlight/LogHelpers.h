#ifndef LOG_HELPERS_H
#define LOG_HELPERS_H

#ifdef __cplusplus
extern "C" {
#endif

// C callback function that formats variadic arguments and calls Swift
void logMessageCallback(const char* format, ...);

// Helper function to get the function pointer for Swift
void* getLogMessageCallbackPointer(void);

#ifdef __cplusplus
}
#endif

#endif // LOG_HELPERS_H
