## [unreleased]

### 🚀 Features

- Add ci action
- Add README.md and LICENSE files
- Add pull request template
- Add issue templates
- Add TokenType enum to define token categories
- Add TokenData union for enhanced token representation
- Add Pos struct for representing position in source files
- Add Token struct for representing tokens with type and data
- Implement Token struct and associated types for token representation
- Update Token initialization to use string data type
- Add NumberType enum and extend Token struct for numeric literals
- Implement TranspileProcess for file handling and token management
- Refactor TranspileProcess to simplify resource management and enhance initialization
- Add LexProcess for lexical analysis and integrate with TranspileProcess
- Enhance LexProcess with character handling and update TranspileProcess initialization
- Update TokenData structure to use ArrayList for sval
- Introduce TranspileProcessFlags enum and add error/warning logging methods
- Implement token handling for comments and newlines in LexProcess
- Add whitespace handling in LexProcess and update debug output for tokens
- Add functions to check for datatype and general keywords in LexProcess
- Enhance LexProcess with identifier and keyword token handling
- Implement number token handling in LexProcess
- Implement symbol and operator token handling in LexProcess
- Add support for binary and hexadecimal number tokens in LexProcess
- Call deinit in error_message to ensure proper resource cleanup
- Improve push_char and token handling in LexProcess for better input stream management
- Enhance token handling in LexProcess to support string tokens and escape sequences
- Add support for character tokens in LexProcess and update token handling
- Enhance LexProcess to support nested expressions and improve buffer management
- Add tests for LexProcess and TranspileProcess initialization and functionality
- Add 'chr' datatype keyword support in keyword_is_datatype function
- Add allocator field to LexProcess and TranspileProcess for improved memory management
- Implement abstract syntax tree (AST) and data type structures for transpiler
- Add generic Vector type with various manipulation methods
- Add push_slice method to Vector for appending slices of elements
- Implement parsing process with token handling in transpiler
- Add History struct with flags and fit statement branches
- Refactor flags to use packed structs for NodeFlags, DataTypeFlags, HistoryFlags, and TranspileProcessFlags
- Enhance ParseProcess with memory allocator and prep keyword parsing functionality
- Enhance DataType and LexProcess with nullable fields and position tracking
- Add Bracket node type and enhance node type checks for expressions and values
- Enhance History and Node structures with additional flags and nullable fields
- Enhance parsing logic for identifiers and strings, and improve variable handling
- Improve error handling by enhancing error messages with context and formatting
- Enhance expression handling with new node types and operator precedence structure
- Add function declarations and enhance node structures with nullable fields
- Enhance AST and parser with return statement handling and improved body parsing
- Enhance variable debugging output and ensure semicolon expectation in parser
- Update expression handling with nullable left nodes and improve main function debugging output
- Enhance data type handling with array support and improve parser functionality
- Add support for if, elif, and else statements in AST and parser
- Refactor body parsing to remove single statement handling in parser
- Add boolean node support in AST and lexer, enhance parsing for boolean literals
- Add boolean type support in expression evaluation and update test case
- Implement fit statement support in AST and parser, enhance parsing for fit branches
- Add import node support in AST and parser, implement import parsing logic
- Enhance fit statement syntax and update README
- Add peek_decrement flag to Vector for flexible peek behavior
- Implement Scope structure for transpiler with entity management
- Update Vector and Scope for improved peek behavior and iteration
- Improve AST structure and memory management, add VSCode configuration files for debugging purposes
- Update CI workflow to use Zig version 0.13.0
- Refactor add function to use pointers and enhance main function with improved logic and output
- Add AST node printing functionality to main function
- Add body parsing functionality and update parse_body error handling
- Add cli support
- Update CI workflow and enhance CLI usage documentation
- Add symbol table implementation and integrate with transpiler
- Enhance transpiler with node symbol registration and update symbol structure
- Add transpile functionality
- Add custom addition function and update test cases for circular dependency detection
- Enhance circular dependency detection with import chain tracking
- Implement recursive transpilation and enhance import handling
- Duplicate symbols accross modules
- Update CLI execution path
- Restructure imports and add new examples for symbol and data type handling
- Enhance memory allocation strategy with conditional debug allocator
- Enhance transpilation error handling with detailed error reporting
- Enhance error handling in transpilation and lexical analysis processes
- Enhance error handling in transpilation and parsing processes
- Improve error handling and reporting across CLI, parser, lexer, and transpiler modules
- Enhance error handling and reporting in transpilation, parsing, and CLI modules
- Add Code of Conduct, contributing guidelines, and comprehensive documentation for the fun language
- Add error handling for undeclared and already declared variables in transpilation process
- Add error cases for already declared and undeclared variables in examples
- Add example for undeclared symbols in specific scopes
- Add example for undeclared symbols in function arguments and clean up scope handling in parser
- Enhance global symbol registration in ParseProcess and handle std.io imports
- Improve entity initialization in scope tests by adding names to entities
- Add error handling for invalid function declarations in parser and update examples
- Enhance error handling and reporting in transpilation, parsing, and CLI modules; add documentation and examples for variable declaration errors
- Remove unused example function from main in test.fn
- Remove unused print statements from circular dependency examples and missing import case; enhance token position tracking in lexer and parser
- Enhance token position tracking and import handling; add tests for global symbol preloading
- Add circular import detection in transpiler; enhance example outputs for clarity
- Add error handling for missing C compiler and improve executable naming on Windows
- Add exhaustive fit warning handling and related tests
- Add exhaustive fit warning handling and related tests (#56)
- Implement type checking with error handling for mismatches and add related tests
- Enhance assignment operator handling in transpilation process
- Implement type checking with error handling for mismatches and … (#57)
- Add comprehensive tests for CLI, code generation, parsing, and type checking modules
- Add comprehensive tests for CLI, code generation, parsing, and type checking modules (#58)
- Implement in-place file formatting and add related tests
- Add in-place formatting for all imported modules and enhance CLI options
- Improve comment formatting by adding a space after "//" in token output
- Add release workflow for building and uploading artifacts across multiple platforms
- Add release workflow for building and uploading artifacts across multiple platforms (#60)

### 🐛 Bug Fixes

- Correct loop condition in read_op_flush_back_keep_first function to prevent pushing the first character
- Improve memory management in lexer and parser
- Conditional statements parsing
- Add error handling for conditional statements outside of functions
- Update symbol table references to use pointer types
- Remove unused symbol import from main module
- Improve folder identifier parsing
- Enhance circular dependency detection with detailed error messages
- Properly clean up global_symbols hash map during deinitialization
- Remove unnecessary flags from Zig build command in CI workflow
- Correct path to test file in CI workflow
- Update file paths in launch configuration and build settings

### 🚜 Refactor

- Improve deinit function and simplify main loop printing
- Remove unused test for parsing if statements
- Enhance scope management in transpiler and parser
- Streamline node creation and scope entity handling in parser and transpiler
- Remove escape handling from lexer
- Clean up whitespace in compile_and_run function
- Update documentation for scope entity return types

### 📚 Documentation

- Add docs for `LexProcess` structure
- Lexer strings functions
- Add token_make_character documentation
- Add start_expression documentation
- Add documentation for the used functions
- Add detailed documentation for parser and transpiler scope functions

### 🎨 Styling

- Format code for consistency and readability

### ⚙️ Miscellaneous Tasks

- Move print_node function to misc
- Update Zig version to 0.14.0 and adjust build configurations
- Format parser
- Enable incremental builds in CI workflow and update build configuration
- Create a single consolidated test module to cover all modules
- Add comprehensive changelog documenting features, bug fixes, refactors, and enhancements
