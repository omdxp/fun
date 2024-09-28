# fun

fun is a statically-typed programming language that transpiles to C. It aims to provide the safety and performance of static typing while leveraging the power and efficiency of C.

There will be a lot to come along the way. Here is a glimpse:

```fun
imp std.io;

fun add(num one, num two) num {
    ret one + two;
}

fun main(str[] args) {
    num res = add(1, 2); // add two numbers
    if res == 3 {
        printf("%d is 3", res);
    } elif res < 3 {
        printf("%d is less than 3", res);
    } else {
        printf("%d is above than 3", res);
    }

    bin x = false;
    fit x {
        true -> printf("x is true");
        false -> printf("x is false");
    }

    str hello = "Hello, World!";
    printf("%s\n", hello);
}
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
