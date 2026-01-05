## [unreleased]

### 🚀 Features

- Feat: implement `sizeof` operator support with hover, completion, and signature help
- Feat: add enum support with shorthand syntax and enhance parsing

- Implemented parsing for enum declarations, allowing shorthand syntax for enum variants (e.g., `.Variant`).
- Updated lexer to recognize `==` as a single operator token, accommodating whitespace.
- Enhanced the parser to handle enum variant shorthand in fit statements and expressions.
- Added tests to verify correct behavior for enum variant exhaustiveness and shorthand usage.
- Improved utility functions to recognize new keywords related to enums.
- Feat: improve token emission formatting and ensure spacing for operators before dot shorthand
## [0.14.3] - 2026-01-05

### 🚀 Features

- Feat: add support for `sizeof` operator and related error handling in transpilation
## [0.14.2] - 2026-01-05

### 🚀 Features

- Feat: add custom import namespace hover functionality to display README content
- Feat: add new transpilation error types and enhance type checking tests for variadic arguments
## [0.14.1] - 2026-01-04

### 🚀 Features

- Feat: enhance fit statement exhaustiveness checks and add related tests
- Feat: add parameter handling to signature help and enhance related tests

### 💼 Other

- Enhance C standard library bindings and add macro completions

- Updated `transpiler.zig` to recognize additional C constants from `limits.h`.
- Enhanced `misc.zig` to include `wchar_t` and `rsize_t` in type alias handling.
- Expanded `ctype.fn` with detailed function documentation for character classification.
- Improved `io.fn` with comprehensive documentation for standard I/O functions.
- Updated `limits.fn` to provide detailed descriptions of C limits and macros.
- Enhanced `math.fn` with additional mathematical functions and documentation.
- Expanded `mem.fn` to include detailed memory management functions and their semantics.
- Updated `stddef.fn` to provide clear documentation on common typedefs and macros.
- Enhanced `string.fn` with comprehensive string manipulation functions and documentation.
- Updated `time.fn` to include detailed time and date functions with documentation.
- Added end-to-end tests for C macro completions in `std.c.limits` and `std.c.stddef`.
- Added tests to verify hover documentation for the standard library namespace.
## [0.14.0] - 2026-01-04

### 🚀 Features

- Feat: enhance environment variable handling in installer scripts for better path resolution
- Feat: add diagnostics for returning address of local variables and implement related tests
- Feat: improve module and directory handling in LSP server for better file resolution

### 📚 Documentation

- Docs: update Zig version recommendation in README to reference build.zig.zon
## [0.13.3] - 2026-01-04

### 🚀 Features

- Feat: update .gitignore and add initial implementation of Fun Language Server
## [0.13.2] - 2026-01-04

### 🚀 Features

- Feat: update README to clarify prerequisites and enhance getting started instructions
- Feat: enhance debugging options and logging for the Fun language server
## [0.13.1] - 2026-01-04

### 🚀 Features

- Feat: enhance symbol collection to support pointer and reference types in function parameters
- Feat: enhance build process to stage test binaries and improve error handling in imports
- Feat: enhance function and variable type handling in LSP server responses
## [0.13.0] - 2026-01-04

### 🚀 Features

- Feat: enhance formatting for pointer types in function signatures

### 💼 Other

- Add support for parent traversal in imports and enhance completion features

- Implemented parent traversal for imports using dot runs (e.g., `..` for one parent, `....` for two parents).
- Added tests to verify completion of methods across files, ensuring that methods from implementations in different files are suggested correctly.
- Introduced new examples demonstrating the use of imports and implementations across multiple files.
- Enhanced the formatting tool to correctly format parent traversal imports.
- Updated the standard library function signatures to use consistent pointer notation.
## [0.12.12] - 2026-01-04

### 🚀 Features

- Feat: enhance formatting for pointer and address-of spacing in CLI
## [0.12.11] - 2026-01-04

### 🚀 Features

- Feat: improve version extraction and validation in release workflows
## [0.12.10] - 2026-01-04

### 🚀 Features

- Feat: enhance release workflow with version verification and tag resolution
## [0.12.9] - 2026-01-04

### 🚀 Features

- Feat: enhance release workflow to correctly handle release tags
## [0.12.8] - 2026-01-04

### 🚀 Features

- Feat: improve version handling in CLI and update usage instructions
## [0.12.7] - 2026-01-04

### 🚀 Features

- Feat: enhance LspServer to support stdlib namespace completions and hover information
- Feat: add version option to CLI and update usage instructions
- Feat: add version tagging to build process in release workflow
## [0.12.6] - 2026-01-03

### 🚀 Features

- Feat: enhance LspServer and TranspileProcess to improve file handling and error reporting on Windows
## [0.12.5] - 2026-01-03

### 🚀 Features

- Feat: enhance LspServer to support multiple executable directory layouts for stdlib root detection
## [0.12.4] - 2026-01-03

### 🚀 Features

- Feat: enhance LSP server to support directory walking for stdlib root detection; improve error handling for unknown function calls
## [0.12.3] - 2026-01-03

### 🚀 Features

- Feat: enhance LSP server to resolve stdlib paths and improve import handling; add operator syntax highlighting
## [0.12.2] - 2026-01-03

### 🚀 Features

- Feat: enhance installation and uninstallation scripts to manage FUN_STDLIB_DIR environment variable
- Feat: add guards and separate functions for emitting impl bodies and vtables in TranspileProcess
- Feat: enhance symbol indexing to include locals and parameters in impl methods
- Feat: update isStdlibRoot function to handle absolute paths and improve directory validation
## [0.12.1] - 2026-01-03

### 🚀 Features

- Feat: update install and uninstall scripts to handle 'fls' binary
## [0.12.0] - 2026-01-03

### 🚀 Features

- Feat: add debug logging and error handling for argument and body parsing in ParseProcess
- Feat: add stdlib root path handling and cleanup in LspServer

### 💼 Other

- Refactor imports to use std.c.* modules

- Updated all instances of `imp std.io;` to `imp std.c.io;` across various example files, tests, and the transpiler.
- Introduced new C standard library signature modules under `stdlib/std/c/` for `ctype`, `io`, `limits`, `math`, `mem`, `stddef`, `string`, and `time`.
- Removed the legacy `stdlib/std/io.fn` file to streamline the import process.
- Adjusted code generation logic to support both `std.io` and `std.c.io` imports, ensuring backward compatibility.
## [0.11.7] - 2026-01-03

### 🚀 Features

- Feat: enhance error handling for temporary directory and lexer/parser processes
## [0.11.6] - 2026-01-03

### 🚀 Features

- Feat: improve temporary file handling in buildIndexFromText function
- Feat: implement temporary directory cleanup for fls
## [0.11.5] - 2026-01-03

### 🐛 Bug Fixes

- Fix: update publisher field in package.json to "omdxp"
## [0.11.4] - 2026-01-03

### 🚀 Features

- Feat: update display name to "Fun (FLS) for VS Code" for clarity
## [0.11.3] - 2026-01-03

### 🚀 Features

- Feat: update display name to "Fun Language Support" for clarity
## [0.11.2] - 2026-01-03

### 🚀 Features

- Feat: add package path and base URLs for VSCE publish command in workflow
## [0.11.1] - 2026-01-03

### 🚀 Features

- Feat: add base URL handling for README links in VS Code extension packaging
## [0.11.0] - 2026-01-03

### 🚀 Features

- Feat: update VS Code extension prerequisites and version

- Added prerequisites section to README.md for the Fun language extension, specifying the need for `fun` and `fls` to be installed and accessible in the system PATH.
- Updated version numbers in package.json and package-lock.json from 0.1.3 to 0.1.4.

fix: improve transpiler error handling and parsing robustness

- Refined error reporting in transpiler.zig to avoid double-close crashes on Windows.
- Enhanced parsing logic in parser.zig to handle malformed input gracefully without crashing.
- Added tests to ensure that the parser returns errors on malformed input without crashing.

test: expand end-to-end tests for function and member completion

- Added tests for local variable completion, member function calls, and hover information in fls_e2e_test.zig.
- Implemented checks for signature help and semantic tokens to ensure proper functionality in the language server.
- Feat: implement CI skip logic for fls_e2e_test.zig
- Feat: exclude LSP-related tests in CI workflow
- Feat: enhance CI workflow to handle expected stderr during test runs
- Feat: improve CI test handling for known fls failures and unexpected stderr
- Feat: normalize file paths for cross-platform compatibility in tests
- Feat: add hex dump for debugging platform issues in fls test
- Feat: format string arguments for improved readability in tests
- Feat: enhance error handling for format strings in transpiler and improve boolean value printing in utils
- Feat: enhance cross-platform file URI handling in pathToUri and uriToPath functions

### 💼 Other

- Add end-to-end test and fix typecheck for missing methods in quirk implementation

- Imported `fls_e2e_test.zig` into the main test suite for comprehensive testing coverage.
- Added a new test case in `typecheck_test.zig` to verify error handling for missing methods in quirk implementations.
- Refactor VSCode settings and tasks; enhance LSP server documentation handling

- Removed unnecessary paths from `.vscode/settings.json`.
- Added new tasks in `.vscode/tasks.json` to manage `fls` processes and capture logs.
- Updated `main.zig` in the LSP server to append documentation comments above relevant lines.
- Introduced functions to trim whitespace and manage documentation comments.
- Modified `extension.js` to simplify executable resolution logic.
- Updated `package.json` and `package-lock.json` to version 0.1.3.
- Enhanced syntax highlighting in `fun.tmLanguage.json` for type declarations.
- Cleaned up example code in `quirks.fn` for better readability.
- Improved CLI token handling in `cli.zig` to ensure proper formatting.
- Adjusted lexer behavior to prevent invalid operator tokens in `lexer.zig`.
- Added new tests in `fmt_test.zig` to ensure formatting correctness and preserve blank lines.

### 📚 Documentation

- Docs: update README files for consistency and clarity; enhance module descriptions

### ⚙️ Miscellaneous Tasks

- Ci: skip unstable LSP tests in CI workflow and update main_test.zig
## [0.10.0] - 2026-01-01

### 🚀 Features

- Feat: enhance C standard library compatibility with new examples and typedef support
- Feat: update time_format_now example to use time_t for epoch seconds and human-readable format
- Feat: add support for out-of-order function definitions by emitting prototypes

### 💼 Other

- Enhance language features and parser for quirk and plain implementations

- Updated language documentation to include new features: compounds, quirks, and their implementations.
- Expanded the example for quirks to demonstrate area and translation methods for shapes.
- Introduced a new example showcasing declaration order for compound types.
- Added a new file for plain implementation methods on compounds.
- Modified the AST structure to support optional quirk names in implementation nodes.
- Enhanced transpiler to handle cyclic dependencies in compound types and support plain implementation method calls.
- Improved parser to differentiate between quirk and plain implementations, allowing for better error handling and parsing of body statements.
## [0.7.0] - 2026-01-01

### 🚀 Features

- Feat: add read-write initialization for TranspileProcess to support in-place file modifications
## [0.6.3] - 2026-01-01

### 🚀 Features

- Feat: ensure INSTALLFOLDER is created before adding to PATH
## [0.6.2] - 2026-01-01

### 🚀 Features

- Feat: enhance WiX build process with improved logging and argument handling
## [0.6.1] - 2026-01-01

### 🚀 Features

- Feat: normalize version tags for WiX Product/@Version in release workflow
## [0.6.0] - 2026-01-01

### 🚀 Features

- Feat: enhance parser and semantics for variadic functions and raw types

- Updated `ParseProcess` to support variadic function declarations, including parsing and returning a flag indicating if the function is variadic.
- Introduced a new `Raw` data type in `DataTypeType` to represent opaque types.
- Modified the `DataTypeFlags` structure to accommodate pointer flags correctly.
- Enhanced utility functions to recognize the new `raw` data type in keywords and datatype checks.
- Added function signatures for standard library modules, including `ctype`, `io`, `math`, `mem`, `string`, and `time`, to facilitate C standard library integration.
- Implemented installation scripts for both PowerShell and shell environments to streamline the installation process.
- Created uninstallation scripts to remove installed components cleanly.
- Added tests for variadic function parsing and type checking to ensure correctness.
- Feat: add new for loop syntax support and corresponding tests
- Feat: add support for passing program arguments to compiled executables
## [0.3.1] - 2026-01-01

### 🚀 Features

- Feat: enhance transpiler and parser error handling with improved position tracking
## [0.3.0] - 2026-01-01

### 🚀 Features

- Feat: enhance run_examples.ps1 to dynamically resolve RepoRoot if not provided
- Feat: add identifier sanitization for transpilation process
- Feat: add caching for quirk signature hashes in TypeRegistry
## [0.2.0] - 2026-01-01

### 🚀 Features

- Feat: add tests for function calls with varying argument counts and types
- Feat: enhance language support with decimal type and character literals, update lexer and parser for new number handling
- Feat: add support for compounds, quirks, and implementations

- Implemented parsing for `compound`, `quirk`, and `impl` constructs in the parser.
- Introduced functions to handle token peeking for non-skippable tokens.
- Enhanced datatype parsing to recognize user-defined types and handle pointer depth.
- Updated the transpilation process to generate appropriate C code for compounds and quirks, including vtable support.
- Added tests for compound field access, quirk method calls, and coercion from implementations.
- Updated utility functions to recognize new keywords and data types, including `void`.
- Feat: add support for compounds, quirks, and implementations (#62)

- Implemented parsing for `compound`, `quirk`, and `impl` constructs in
the parser.
- Introduced functions to handle token peeking for non-skippable tokens.
- Enhanced datatype parsing to recognize user-defined types and handle
pointer depth.
- Updated the transpilation process to generate appropriate C code for
compounds and quirks, including vtable support.
- Added tests for compound field access, quirk method calls, and
coercion from implementations.
- Updated utility functions to recognize new keywords and data types,
including `void`.
## [0.1.15] - 2025-12-31

### 🚀 Features

- Feat: rename built binaries to include target in release workflow
## [0.1.14] - 2025-12-31

### 🚀 Features

- Feat: update release workflow to include both 'fun' and 'fun.exe' artifacts
## [0.1.13] - 2025-12-31

### 🚀 Features

- Feat: remove update-changelog job from release workflow
- Feat: update CHANGELOG.md to reflect recent changes and enhancements
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
