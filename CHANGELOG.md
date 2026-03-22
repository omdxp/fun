## [0.25.0] - 2026-03-22

### Chore

- *(deps-dev)* Bump undici
- *(deps-dev)* Bump undici from 7.16.0 to 7.24.1 in /editors/vscode in the npm_and_yarn group across 1 directory (#76)

### Feat

- Implement alias handling for compound types and enhance transpiler with canonical name resolution
- Introduce Result type and enhance error handling across stdlib
- Implement best-effort type inference for let variables in LSP indexing
- Add cleanup functionality to example scripts and enhance cache management
- Enhance multi-file snippet support and improve markdown rendering
- Enhance stdlib module exploration with modal support and improved styling

## [0.24.1] - 2026-03-02

### Feat

- Enhance Windows compiler configuration and cleanup in uninstall script
- Enhance symbol grouping in documentation with collapsible sections and styling

## [0.24.0] - 2026-03-02

### Feat

- Enhance asm block handling to support computed operands and preserve formatting

## [0.23.1] - 2026-03-01

### Feat

- Update asm block handling to preserve newlines and add corresponding test case

### Fix

- Update asm block in test to remove architecture specification

## [0.23.0] - 2026-03-01

### Fix

- Update import alias in e2e test and adjust expected completion label

## [0.22.5] - 2026-03-01

### Feat

- Enhance parser to support qualified user-defined types and improve type segment parsing

## [0.22.3] - 2026-03-01

### Feat

- Update search input to be sticky and remove sticky styling from detail card for improved layout

## [0.22.2] - 2026-03-01

### Feat

- Enhance MarkdownWithPlayground component with sourcePath prop and improve link handling; update styles for better accessibility and responsiveness

## [0.22.1] - 2026-03-01

### Feat

- Remove environment configuration from GitHub Pages deployment step

## [0.22.0] - 2026-03-01

### Chore

- *(deps-dev)* Bump qs
- *(deps-dev)* Bump qs from 6.14.1 to 6.14.2 in /editors/vscode in the npm_and_yarn group across 1 directory (#74)
- *(deps)* Bump the npm_and_yarn group across 1 directory with 1 update
- *(deps)* Bump the npm_and_yarn group across 1 directory with 1 update (#75)

### Feat

- Enhance Fun language with new features and type inference
- Enhance type checking for enums as numeric values and improve transpiler logic
- Add example for explicit main exit status and enhance transpiler logic for return values
- Add support for import aliases in transpiler
- Enhance socket and network functionality with additional API methods
- Add content generation and synchronization scripts for Fun language reference
- Add environment variable for FUN_STDLIB_DIR in examples job
- Update run_examples.sh to use FUN_STDLIB_DIR environment variable and capture failure details
- Improve hash function in Map implementation with modular arithmetic

### Fix

- Correct command for running examples in README

## [0.21.2] - 2026-02-05

### Chore

- Enable conventional commits in cliff.toml

### Feat

- Enhance enum exhaustiveness checking in transpile process

## [0.20.3] - 2026-02-04

### Feat

- Add GitHub Actions section to README for CI installation instructions
- Update C compiler selection details in README for macOS/Linux and Windows
- Update cache directory structure to use .fun-cache for CLI operations

## [0.20.2] - 2026-02-04

### Feat

- Update compiler settings to use gcc for linux and macos and MSVC for windows instead of zig in installation scripts

## [0.20.1] - 2026-02-04

### Feat

- Enhance transpilation process with generic compound specialization support

## [0.20.0] - 2026-02-04

### Feat

- Add editor support documentation and syntax highlighting for Fun language
- Update .gitattributes for Zig syntax highlighting and enhance README with compiler selection and editor support sections

## [0.19.1] - 2026-02-04

### Feat

- Add .gitattributes to specify linguist language for .fn files

## [0.19.0] - 2026-02-04

### Feat

- Enhance stdlib with new functionalities and improvements
- Add support for generic types in syntax highlighting
- Add assert statement with optional message and update related examples

## [0.18.2] - 2026-02-04

### Test

- Add end-to-end test for generic type member completion (Vec<T>)

## [0.18.1] - 2026-02-04

### Feat

- Enhance install script to support fallback for POSIX shells and add compiler environment variables

## [0.18.0] - 2026-02-04

### Docs

- Update README and documentation for 64-bit numeric types and add reference.md
- Enhance documentation for standard library and add POSIX socket support

## [0.17.1] - 2026-02-03

### Fix

- Update return values in IO and Result functions to use boolean types

## [0.17.0] - 2026-02-03

### Feat

- Enhance keyword and datatype handling, improve visibility and access control
- Update C stdlib imports to use 'std.c.def' for compatibility
- Enhance keyword and datatype handling, improve visibility and access control (#69)
- Add inline assembly support with volatile options and architecture guards
- Add inline assembly support with volatile options and architecture guards (#71)

## [0.16.1] - 2026-02-02

### Feat

- Refactor defer block handling in parser and enhance demo functions

## [0.16.0] - 2026-02-02

### Feat

- Add defer keyword support with LIFO execution and update documentation
- Add defer keyword support with LIFO execution and update documentation (#68)

## [0.15.5] - 2026-02-02

### Feat

- Implement inferDeclTypeBeforeName function and enhance exe path resolution in tests

## [0.15.4] - 2026-02-02

### Feat

- Add insertText and filterText fields to CompletionItem in LspServer

## [0.15.3] - 2026-02-02

### Feat

- Enhance enum support with shorthand access and update documentation

## [0.15.2] - 2026-02-01

### Feat

- Add support for referencing enum types before declaration in codegen

### Fix

- Correct indentation in LspServer struct for improved readability

## [0.15.1] - 2026-02-01

### Chore

- *(deps-dev)* Bump lodash
- *(deps-dev)* Bump lodash from 4.17.21 to 4.17.23 in /editors/vscode in the npm_and_yarn group across 1 directory (#66)

### Feat

- Add LSP support for enum dot shorthand completion, hover, and definition
- Add LSP support for enum dot shorthand completion, hover, and definition (#67)

## [0.15.0] - 2026-01-05

### Feat

- Implement `sizeof` operator support with hover, completion, and signature help
- Add enum support with shorthand syntax and enhance parsing
- Improve token emission formatting and ensure spacing for operators before dot shorthand
- Update CHANGELOG.md to reflect recent changes and enhancements

## [0.14.3] - 2026-01-05

### Feat

- Add support for `sizeof` operator and related error handling in transpilation

## [0.14.2] - 2026-01-05

### Feat

- Add custom import namespace hover functionality to display README content
- Add new transpilation error types and enhance type checking tests for variadic arguments

## [0.14.1] - 2026-01-04

### Feat

- Enhance fit statement exhaustiveness checks and add related tests
- Add parameter handling to signature help and enhance related tests

## [0.14.0] - 2026-01-04

### Docs

- Update Zig version recommendation in README to reference build.zig.zon

### Feat

- Enhance environment variable handling in installer scripts for better path resolution
- Add diagnostics for returning address of local variables and implement related tests
- Improve module and directory handling in LSP server for better file resolution

## [0.13.3] - 2026-01-04

### Feat

- Update .gitignore and add initial implementation of Fun Language Server

## [0.13.2] - 2026-01-04

### Feat

- Update README to clarify prerequisites and enhance getting started instructions
- Enhance debugging options and logging for the Fun language server

## [0.13.1] - 2026-01-04

### Feat

- Enhance symbol collection to support pointer and reference types in function parameters
- Enhance build process to stage test binaries and improve error handling in imports
- Enhance function and variable type handling in LSP server responses

## [0.13.0] - 2026-01-04

### Feat

- Enhance formatting for pointer types in function signatures

## [0.12.12] - 2026-01-04

### Feat

- Enhance formatting for pointer and address-of spacing in CLI

## [0.12.11] - 2026-01-04

### Feat

- Improve version extraction and validation in release workflows

## [0.12.10] - 2026-01-04

### Feat

- Enhance release workflow with version verification and tag resolution

## [0.12.9] - 2026-01-04

### Feat

- Enhance release workflow to correctly handle release tags

## [0.12.8] - 2026-01-04

### Feat

- Improve version handling in CLI and update usage instructions

## [0.12.7] - 2026-01-04

### Feat

- Enhance LspServer to support stdlib namespace completions and hover information
- Add version option to CLI and update usage instructions
- Add version tagging to build process in release workflow

## [0.12.6] - 2026-01-03

### Feat

- Enhance LspServer and TranspileProcess to improve file handling and error reporting on Windows

## [0.12.5] - 2026-01-03

### Feat

- Enhance LspServer to support multiple executable directory layouts for stdlib root detection

## [0.12.4] - 2026-01-03

### Feat

- Enhance LSP server to support directory walking for stdlib root detection; improve error handling for unknown function calls

## [0.12.3] - 2026-01-03

### Feat

- Enhance LSP server to resolve stdlib paths and improve import handling; add operator syntax highlighting

## [0.12.2] - 2026-01-03

### Feat

- Enhance installation and uninstallation scripts to manage FUN_STDLIB_DIR environment variable
- Add guards and separate functions for emitting impl bodies and vtables in TranspileProcess
- Enhance symbol indexing to include locals and parameters in impl methods
- Update isStdlibRoot function to handle absolute paths and improve directory validation

## [0.12.1] - 2026-01-03

### Feat

- Update install and uninstall scripts to handle 'fls' binary

## [0.12.0] - 2026-01-03

### Feat

- Add debug logging and error handling for argument and body parsing in ParseProcess
- Add stdlib root path handling and cleanup in LspServer

## [0.11.7] - 2026-01-03

### Feat

- Enhance error handling for temporary directory and lexer/parser processes

## [0.11.6] - 2026-01-03

### Feat

- Improve temporary file handling in buildIndexFromText function
- Implement temporary directory cleanup for fls

## [0.11.5] - 2026-01-03

### Fix

- Update publisher field in package.json to "omdxp"

## [0.11.4] - 2026-01-03

### Feat

- Update display name to "Fun (FLS) for VS Code" for clarity

## [0.11.3] - 2026-01-03

### Feat

- Update display name to "Fun Language Support" for clarity

## [0.11.2] - 2026-01-03

### Feat

- Add package path and base URLs for VSCE publish command in workflow

## [0.11.1] - 2026-01-03

### Feat

- Add base URL handling for README links in VS Code extension packaging

## [0.11.0] - 2026-01-03

### Ci

- Skip unstable LSP tests in CI workflow and update main_test.zig

### Docs

- Update README files for consistency and clarity; enhance module descriptions

### Feat

- Update VS Code extension prerequisites and version
- Implement CI skip logic for fls_e2e_test.zig
- Exclude LSP-related tests in CI workflow
- Enhance CI workflow to handle expected stderr during test runs
- Improve CI test handling for known fls failures and unexpected stderr
- Normalize file paths for cross-platform compatibility in tests
- Add hex dump for debugging platform issues in fls test
- Format string arguments for improved readability in tests
- Enhance error handling for format strings in transpiler and improve boolean value printing in utils
- Enhance cross-platform file URI handling in pathToUri and uriToPath functions

## [0.10.0] - 2026-01-01

### Feat

- Enhance C standard library compatibility with new examples and typedef support
- Update time_format_now example to use time_t for epoch seconds and human-readable format
- Add support for out-of-order function definitions by emitting prototypes

## [0.7.0] - 2026-01-01

### Feat

- Add read-write initialization for TranspileProcess to support in-place file modifications

## [0.6.3] - 2026-01-01

### Feat

- Ensure INSTALLFOLDER is created before adding to PATH

## [0.6.2] - 2026-01-01

### Feat

- Enhance WiX build process with improved logging and argument handling

## [0.6.1] - 2026-01-01

### Feat

- Normalize version tags for WiX Product/@Version in release workflow

## [0.6.0] - 2026-01-01

### Feat

- Enhance parser and semantics for variadic functions and raw types
- Add new for loop syntax support and corresponding tests
- Add support for passing program arguments to compiled executables

## [0.3.1] - 2026-01-01

### Feat

- Enhance transpiler and parser error handling with improved position tracking

## [0.3.0] - 2026-01-01

### Feat

- Enhance run_examples.ps1 to dynamically resolve RepoRoot if not provided
- Add identifier sanitization for transpilation process
- Add caching for quirk signature hashes in TypeRegistry

## [0.2.0] - 2026-01-01

### Feat

- Add tests for function calls with varying argument counts and types
- Enhance language support with decimal type and character literals, update lexer and parser for new number handling
- Add support for compounds, quirks, and implementations
- Add support for compounds, quirks, and implementations (#62)

## [0.1.15] - 2025-12-31

### Feat

- Rename built binaries to include target in release workflow

## [0.1.14] - 2025-12-31

### Feat

- Update release workflow to include both 'fun' and 'fun.exe' artifacts

## [0.1.13] - 2025-12-31

### Feat

- Remove update-changelog job from release workflow
- Update CHANGELOG.md to reflect recent changes and enhancements

## [0.1.11] - 2025-12-31

### Feat

- Remove debug step for GH_PAT in release workflow

## [0.1.10] - 2025-12-31

### Feat

- Add debug step to check GH_PAT environment variable in release workflow

## [0.1.9] - 2025-12-31

### Feat

- Update git remote URL to use personal access token for pushing changes

## [0.1.7] - 2025-12-31

### Feat

- Update release workflow to use personal access token and add cliff configuration

## [0.1.5] - 2025-12-31

### Feat

- Simplify git-cliff installation method in release workflow

## [0.1.3] - 2025-12-31

### Feat

- Fix git-cliff installation path in release workflow

## [0.1.2] - 2025-12-31

### Feat

- Fix git-cliff installation path in release workflow

## [0.1.1] - 2025-12-31

### Feat

- Update git-cliff installation method and build configuration

## [0.1.0] - 2025-12-31

### Chore

- Move print_node function to misc
- Update Zig version to 0.14.0 and adjust build configurations
- Format parser
- Create a single consolidated test module to cover all modules
- Add comprehensive changelog documenting features, bug fixes, refactors, and enhancements
- *(docs)* Update changelog

### Ci

- Enable incremental builds in CI workflow and update build configuration

### Doc

- Add docs for `LexProcess` structure
- Lexer strings functions
- Add token_make_character documentation
- Add start_expression documentation
- Add detailed documentation for parser and transpiler scope functions

### Docs

- Add documentation for the used functions

### Feat

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
- Add job to update and commit CHANGELOG.md on release
- Update git-cliff installation to version 2.11.0

### Fix

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

### Refactor

- Improve deinit function and simplify main loop printing
- Remove unused test for parsing if statements
- Enhance scope management in transpiler and parser
- Streamline node creation and scope entity handling in parser and transpiler
- Remove escape handling from lexer
- Clean up whitespace in compile_and_run function
- Update documentation for scope entity return types

### Style

- Format code for consistency and readability

