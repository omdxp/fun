#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int add(int one, int two) {
    return one + two;
}

int main(int argc, char** argv) {
    int res = add(1, 2);
    if (res == 3) {
        printf("%d is 3", res);
    }
    else if (res < 3) {
        printf("%d is less than 3", res);
    }
    else {
        printf("%d is above than 3", res);
    }
    bool x = false;
    switch (x) {
        case true:
            {
                printf("x is true");
            }
            break;
        case false:
            {
                printf("x is false");
            }
            break;
    }
    char* hello = "Hello, World!";
    printf("%s\n", hello);
}

