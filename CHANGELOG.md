## [unreleased]

### 🚀 Features

- Feat: remove update-changelog job from release workflow
## [0.1.11] - 2025-12-31

### 🚀 Features

- Feat: remove debug step for GH_PAT in release workflow
## [0.1.10] - 2025-12-31

### 🚀 Features

- Feat: add debug step to check GH_PAT environment variable in release workflow
## [0.1.9] - 2025-12-31

### 🚀 Features

- Feat: update git remote URL to use personal access token for pushing changes
## [0.1.7] - 2025-12-31

### 🚀 Features

- Feat: update release workflow to use personal access token and add cliff configuration
## [0.1.5] - 2025-12-31

### 🚀 Features

- Feat: simplify git-cliff installation method in release workflow
## [0.1.3] - 2025-12-31

### 🚀 Features

- Feat: fix git-cliff installation path in release workflow
## [0.1.2] - 2025-12-31

### 🚀 Features

- Feat: fix git-cliff installation path in release workflow
## [0.1.1] - 2025-12-31

### 🚀 Features

- Feat: update git-cliff installation method and build configuration
## [0.1.0] - 2025-12-31

### 🚀 Features

- Feat: add ci action
- Feat: add README.md and LICENSE files
- Feat: add pull request template
- Feat: add issue templates
- Feat: add TokenType enum to define token categories
- Feat: add TokenData union for enhanced token representation
- Feat: add Pos struct for representing position in source files
- Feat: add Token struct for representing tokens with type and data
- Feat: implement Token struct and associated types for token representation
- Feat: update Token initialization to use string data type
- Feat: add NumberType enum and extend Token struct for numeric literals
- Feat: implement TranspileProcess for file handling and token management
- Feat: refactor TranspileProcess to simplify resource management and enhance initialization
- Feat: add LexProcess for lexical analysis and integrate with TranspileProcess
- Feat: enhance LexProcess with character handling and update TranspileProcess initialization
- Feat: update TokenData structure to use ArrayList for sval
- Feat: introduce TranspileProcessFlags enum and add error/warning logging methods
- Feat: implement token handling for comments and newlines in LexProcess
- Feat: add whitespace handling in LexProcess and update debug output for tokens
- Feat: add functions to check for datatype and general keywords in LexProcess
- Feat: enhance LexProcess with identifier and keyword token handling
- Feat: implement number token handling in LexProcess
- Feat: implement symbol and operator token handling in LexProcess
- Feat: add support for binary and hexadecimal number tokens in LexProcess
- Feat: call deinit in error_message to ensure proper resource cleanup
- Feat: improve push_char and token handling in LexProcess for better input stream management
- Feat: enhance token handling in LexProcess to support string tokens and escape sequences
- Feat: add support for character tokens in LexProcess and update token handling
- Feat: enhance LexProcess to support nested expressions and improve buffer management
- Feat: add tests for LexProcess and TranspileProcess initialization and functionality
- Feat: add 'chr' datatype keyword support in keyword_is_datatype function
- Feat: add allocator field to LexProcess and TranspileProcess for improved memory management
- Feat: implement abstract syntax tree (AST) and data type structures for transpiler
- Feat: add generic Vector type with various manipulation methods
- Feat: add push_slice method to Vector for appending slices of elements
- Feat: implement parsing process with token handling in transpiler
- Feat: add History struct with flags and fit statement branches
- Feat: refactor flags to use packed structs for NodeFlags, DataTypeFlags, HistoryFlags, and TranspileProcessFlags
- Feat: enhance ParseProcess with memory allocator and prep keyword parsing functionality
- Feat: enhance DataType and LexProcess with nullable fields and position tracking
- Feat: add Bracket node type and enhance node type checks for expressions and values
- Feat: enhance History and Node structures with additional flags and nullable fields
- Feat: enhance parsing logic for identifiers and strings, and improve variable handling
- Feat: improve error handling by enhancing error messages with context and formatting
- Feat: enhance expression handling with new node types and operator precedence structure
- Feat: add function declarations and enhance node structures with nullable fields
- Feat: enhance AST and parser with return statement handling and improved body parsing
- Feat: enhance variable debugging output and ensure semicolon expectation in parser
- Feat: update expression handling with nullable left nodes and improve main function debugging output
- Feat: enhance data type handling with array support and improve parser functionality
- Feat: add support for if, elif, and else statements in AST and parser
- Feat: refactor body parsing to remove single statement handling in parser
- Feat: add boolean node support in AST and lexer, enhance parsing for boolean literals
- Feat: add boolean type support in expression evaluation and update test case
- Feat: implement fit statement support in AST and parser, enhance parsing for fit branches
- Feat: add import node support in AST and parser, implement import parsing logic
- Feat: enhance fit statement syntax and update README
- Feat: add peek_decrement flag to Vector for flexible peek behavior
- Feat: implement Scope structure for transpiler with entity management
- Feat: update Vector and Scope for improved peek behavior and iteration
- Feat: improve AST structure and memory management, add VSCode configuration files for debugging purposes
- Feat: update CI workflow to use Zig version 0.13.0
- Feat: refactor add function to use pointers and enhance main function with improved logic and output
- Feat: add AST node printing functionality to main function
- Feat: add body parsing functionality and update parse_body error handling
- Feat: add cli support
- Feat: update CI workflow and enhance CLI usage documentation
- Feat: add symbol table implementation and integrate with transpiler
- Feat: enhance transpiler with node symbol registration and update symbol structure
- Feat: add transpile functionality
- Feat: add custom addition function and update test cases for circular dependency detection
- Feat: enhance circular dependency detection with import chain tracking
- Feat: implement recursive transpilation and enhance import handling
- Feat: duplicate symbols accross modules
- Feat: update CLI execution path
- Feat: restructure imports and add new examples for symbol and data type handling
- Feat: enhance memory allocation strategy with conditional debug allocator
- Feat: enhance transpilation error handling with detailed error reporting
- Feat: enhance error handling in transpilation and lexical analysis processes
- Feat: enhance error handling in transpilation and parsing processes
- Feat: improve error handling and reporting across CLI, parser, lexer, and transpiler modules
- Feat: enhance error handling and reporting in transpilation, parsing, and CLI modules
- Feat: add Code of Conduct, contributing guidelines, and comprehensive documentation for the fun language
- Feat: add error handling for undeclared and already declared variables in transpilation process
- Feat: add error cases for already declared and undeclared variables in examples
- Feat: add example for undeclared symbols in specific scopes
- Feat: add example for undeclared symbols in function arguments and clean up scope handling in parser
- Feat: enhance global symbol registration in ParseProcess and handle std.io imports
- Feat: improve entity initialization in scope tests by adding names to entities
- Feat: add error handling for invalid function declarations in parser and update examples
- Feat: enhance error handling and reporting in transpilation, parsing, and CLI modules; add documentation and examples for variable declaration errors
- Feat: remove unused example function from main in test.fn
- Feat: remove unused print statements from circular dependency examples and missing import case; enhance token position tracking in lexer and parser
- Feat: enhance token position tracking and import handling; add tests for global symbol preloading
- Feat: add circular import detection in transpiler; enhance example outputs for clarity
- Feat: add error handling for missing C compiler and improve executable naming on Windows
- Feat: add exhaustive fit warning handling and related tests
- Feat: add exhaustive fit warning handling and related tests (#56)

<!-- Hi, thank you for your contribution! 🔥

Please provide a high-level description of the changes made by your pull
request. If possible, reference related GitHub issues or other pull
requests. For example:

Fixes #123
Resolves #254
See also #23

-->

<!-- After creating your PR, please check the relevant options below -->

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Feat: implement type checking with error handling for mismatches and add related tests
- Feat: enhance assignment operator handling in transpilation process
- Feat: implement type checking with error handling for mismatches and … (#57)

…add related tests

<!-- Hi, thank you for your contribution! 🔥

Please provide a high-level description of the changes made by your pull
request. If possible, reference related GitHub issues or other pull
requests. For example:

Fixes #123
Resolves #254
See also #23

-->

<!-- After creating your PR, please check the relevant options below -->

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Feat: add comprehensive tests for CLI, code generation, parsing, and type checking modules
- Feat: add comprehensive tests for CLI, code generation, parsing, and type checking modules (#58)

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Feat: implement in-place file formatting and add related tests
- Feat: add in-place formatting for all imported modules and enhance CLI options
- Feat: improve comment formatting by adding a space after "//" in token output
- Feat: add release workflow for building and uploading artifacts across multiple platforms
- Feat: add release workflow for building and uploading artifacts across multiple platforms (#60)

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Feat: add job to update and commit CHANGELOG.md on release
- Feat: update git-cliff installation to version 2.11.0

### 🐛 Bug Fixes

- Fix: correct loop condition in read_op_flush_back_keep_first function to prevent pushing the first character
- Fix: improve memory management in lexer and parser
- Fix: conditional statements parsing
- Fix: add error handling for conditional statements outside of functions
- Fix: update symbol table references to use pointer types
- Fix: remove unused symbol import from main module
- Fix: improve folder identifier parsing
- Fix: enhance circular dependency detection with detailed error messages
- Fix: properly clean up global_symbols hash map during deinitialization
- Fix: remove unnecessary flags from Zig build command in CI workflow
- Fix: correct path to test file in CI workflow
- Fix: update file paths in launch configuration and build settings

### 💼 Other

- Init repo
- Add CI workflow (#3)

Resolves #1
- Add `README.md` (#6)

Resolves #2
- Add PR template (#13)

Resovles #4
- Implement token (#24)

Resolves #15 

<!-- After creating your PR, please check the relevant options below -->

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement transpile process (#25)

Resolves #16 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement lexer process (#26)

Resolves #17 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement lexer (#27)

Resolves #18 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement parser (#28)

Resolves #19 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Manage memory in a (slightly) better way (#34)

Fixes #31 

- [x] Bug fix
- [x] New feature
- [ ] Other
- Parse `if` and `elif` statements correctly (#36)

Fixes #35 

- [x] Bug fix
- [ ] New feature
- [ ] Other
- Upgrade Zig to 0.14.0 (#37)

Fixes #32 

- [ ] Bug fix
- [ ] New feature
- [x] Other
- Merge branch 'main' into 21-implement-scopes
- Implement scopes (#30)

Resolves #21 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Add CLI support (#38)

Resolves #33 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement symbol resolver (#43)

Resolves #22 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement code generation (#44)

Resolves #23 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Modular refactoring (#45)

- [ ] Bug fix
- [ ] New feature
- [x] Other
- Conditional Debug Allocator (#48)

Fixes #47 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Better error handling for all transpilation steps (#50)

Resolves #42 

- [ ] Bug fix
- [ ] New feature
- [x] Other
- Handle undeclared symbols (#52)

Resolves #51 

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Introduce token spans (#54)

Resolves #53 

<!-- After creating your PR, please check the relevant options below -->

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Add support for for loops with range and array iteration

- Implemented for loop syntax for iterating over a range (e.g., `for i : start..end { ... }`).
- Added support for iterating over arrays with syntax `for item : arr { ... }` and `for i, item :: arr { ... }`.
- Updated the AST to include nodes for for statements, handling both range and iterable forms.
- Enhanced the parser to recognize and process for loop statements.
- Modified the transpiler to generate equivalent C code for the new for loop constructs.
- Added tests to verify the correct transpilation of for loops with ranges and arrays.
- Add support for for loops with range and array iteration (#55)

- Implemented for loop syntax for iterating over a range (e.g., `for i :
start..end { ... }`).
- Added support for iterating over arrays with syntax `for item : arr {
... }` and `for i, item :: arr { ... }`.
- Updated the AST to include nodes for for statements, handling both
range and iterable forms.
- Enhanced the parser to recognize and process for loop statements.
- Modified the transpiler to generate equivalent C code for the new for
loop constructs.
- Added tests to verify the correct transpilation of for loops with
ranges and arrays.

<!-- Hi, thank you for your contribution! 🔥

Please provide a high-level description of the changes made by your pull
request. If possible, reference related GitHub issues or other pull
requests. For example:

Fixes #123
Resolves #254
See also #23

-->

<!-- After creating your PR, please check the relevant options below -->

- [ ] Bug fix
- [x] New feature
- [ ] Other
- Implement formatter (#59)

- [ ] Bug fix
- [x] New feature
- [ ] Other

### 🚜 Refactor

- Refactor: improve deinit function and simplify main loop printing
- Refactor: remove unused test for parsing if statements
- Refactor: enhance scope management in transpiler and parser
- Refactor: streamline node creation and scope entity handling in parser and transpiler
- Refactor: remove escape handling from lexer
- Refactor: clean up whitespace in compile_and_run function
- Refactor: update documentation for scope entity return types

### 📚 Documentation

- Doc: add docs for `LexProcess` structure
- Doc: lexer strings functions
- Doc: add token_make_character documentation
- Doc: add start_expression documentation
- Docs: add documentation for the used functions
- Doc: add detailed documentation for parser and transpiler scope functions

### 🎨 Styling

- Style: format code for consistency and readability

### ⚙️ Miscellaneous Tasks

- Chore: move print_node function to misc
- Chore: update Zig version to 0.14.0 and adjust build configurations
- Chore: format parser
- Ci: enable incremental builds in CI workflow and update build configuration
- Chore: create a single consolidated test module to cover all modules
- Chore: add comprehensive changelog documenting features, bug fixes, refactors, and enhancements
- Chore(docs): update changelog
