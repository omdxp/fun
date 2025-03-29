// Source file: test.fn

/* Attempting to import: example/custom.fn */

/* Attempting to import: example/folder/subfolder/subfolder2/subfolder3/custom2.fn */
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

int sub(int x, int y) {
    return x - y;
}

int add(int a, int b) {
    return a + b;
}

int main(int argc, char** argv) {
    int result = add(5, 10);
    printf("The result of adding 5 and 10 is: %d\n", result);
}

