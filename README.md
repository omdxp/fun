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
        true -> {
            printf("x is true");
        }
        false -> {
            printf("x is false");
        }
    }

    str hello = "Hello, World!";
    printf("%s\n", hello);
}
```

## CLI Usage
The fun compiler provides several command-line options to control the compilation process:

```
Usage: fun -in <input_file> [-out <output_file>] [-no-exec] [-outf] [-ast] [-help]

Arguments:
  -in      <file>  Input file to compile (required)
  -out     <file>  Output file (optional, defaults to input filename with .c extension)
  -no-exec         Disable automatic compilation and execution (optional, execution enabled by default)
  -outf            Generate .c output file (optional, disabled by default)
  -ast             Print AST nodes (optional, disabled by default)
  -help            Show this help message
```

### Examples

1. Basic compilation and execution:
   ```bash
   fun -in program.fn
   ```
   This will compile program.fn and execute it immediately. The generated C file will be temporary.

2. Generate C file without execution:
   ```bash
   fun -in program.fn -no-exec -outf
   ```
   This will generate program.c without compiling or executing it.

3. Specify output file:
   ```bash
   fun -in program.fn -out custom.c
   ```
   This will generate the C code in custom.c and automatically set -outf to true.

4. View AST nodes:
   ```bash
   fun -in program.fn -ast
   ```
   This will show the Abstract Syntax Tree nodes during compilation.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
