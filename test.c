// Source file: test.fn

/* Attempting to import: example/custom.fn */
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

int add(int x, int y) {
    return x + y;
}

int main(int argc, char** argv) {
    int result = add(5, 10);
    printf("The result of adding 5 and 10 is: %d\n", result);
}

