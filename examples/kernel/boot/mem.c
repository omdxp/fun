#include <stddef.h>
void* memcpy(void* d, const void* s, size_t n) { char* a = d; const char* b = s; while (n--) *a++ = *b++; return d; }
void* memset(void* d, int c, size_t n) { char* a = d; while (n--) *a++ = (char)c; return d; }
void* memmove(void* d, const void* s, size_t n) { char* a = d; const char* b = s; if (a < b) { while (n--) *a++ = *b++; } else { a += n; b += n; while (n--) *--a = *--b; } return d; }
int memcmp(const void* x, const void* y, size_t n) { const unsigned char* a = x; const unsigned char* b = y; for (; n; n--, a++, b++) { if (*a != *b) return *a - *b; } return 0; }
