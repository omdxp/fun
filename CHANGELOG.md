## [0.53.6] - 2026-09-12

### Chore

- Bump version to 0.53.6

### Fix

- *(fls)* PACKAGE_NAME/PACKAGE_VERSION reflect live fun.toml, real goto

## [0.53.5] - 2026-09-12

### Chore

- Bump version to 0.53.5

### Fix

- *(driver)* Add bat-wrapper fallback for cl.exe when INCLUDE not set

## [0.53.4] - 2026-09-12

### Chore

- Bump version to 0.53.4

### Fix

- *(driver)* Source MSVC env automatically on Windows for plain terminals

## [0.53.3] - 2026-09-12

### Chore

- Remove zig cc references from comments in driver and harness
- Bump version to 0.53.3

### Fix

- *(codegen)* Pin #line directives in variadic function preamble
- *(vscode)* Pass MSVC env to fun.exe so it emits MSVC-compatible C

## [0.53.2] - 2026-09-12

### Chore

- Bump version to 0.53.2

### Fix

- *(vscode)* Auto-source MSVC env for debug button on Windows

### ﻿fix

- *(fls,path,deps)* Windows compat for deps hover, completions, run, cache

## [0.53.1] - 2026-09-11

### Chore

- Bump version to 0.53.1

### Docs

- *(deps)* Use single-dash flags for fun add, matching every other CLI flag

### Fix

- *(cli)* Add fun add / fun deps update to -help output
- *(deps)* Fls completion for imp deps., validate fun add upfront
- *(cli)* _run_tests_captured now includes a failed test's stderr

### Test

- *(deps)* Split fls deps-hover test into 3, add failure diagnostics
- *(deps)* Add direct import_target/is_dir diagnostics for the Windows failure
- *(deps)* Isolate tokenizer path from resolve_import_path directly

### ﻿fix

- *(fls)* Is_dir() fallback in _resolve_specifier fixes deps hover on Windows

## [0.53.0] - 2026-09-11

### Chore

- Bump version to 0.53.0

### Docs

- *(deps)* Clarify [lib] has nothing to do with [deps] sharing
- *(deps)* Note that fetching never verifies the repo is a Fun project

### Feat

- *(deps)* Git-based dependency management via [deps] in fun.toml
- *(deps)* Resolve transitive [deps], real fetch bugs found along the way

### Fix

- *(deps)* Correct the earlier WIP commit's diagnosis, no compiler bug
- *(deps)* Format the import_resolver test fixture, add env vars docs
- *(json)* Decode \r escape sequence in JSON string parser
- *(deps)* Replace POSIX-only mv/rm with cross-platform rename on Windows
- *(cli)* Executable_path qualifies bare names on Windows too, use backslash
- *(vscode)* Use `& ` invoker and PowerShell-safe escaping in terminal commands

### Wip

- *(deps)* [deps] manifest table with inline-table dependency entries

## [0.52.5] - 2026-09-10

### Fix

- *(codegen)* Root-cause every remaining -g debug-info gap

## [0.52.4] - 2026-09-10

### Fix

- *(codegen)* Root-cause the stacked-propagation double-evaluation bug

### Refactor

- Re-tighten lookup_fit_variant's ?-chain now that the hoist bug is fixed
- Re-tighten the remaining safe ?-chain sites from the reverted batch

## [0.52.3] - 2026-09-10

### Fix

- *(codegen)* Root-cause the receiver-chain generic-instantiation hoist leak

## [0.52.2] - 2026-09-10

### Chore

- *(release)* Bump to 0.52.2

### Fix

- *(docs)* Remove a stale workaround note, verify and test the real fix
- *(fmt)* Keep a postfix ?/! glued to a chained field access
- *(fls)* Strip the pointer star from a propagated chain's own T
- *(fls)* Strip the pointer star everywhere a propagated T feeds a lookup
- Teach two more fit-subject resolvers about propagation and field access
- *(codegen)* Root-cause a nested-propagation double-eval and MSVC hoist leak

### Refactor

- Inline the 5 originally-reverted ?-chain tightenings
- Inline further single-use ?-chain sites found surveying src/+fls/
- Dispatch directly on indexed elements, no bound pointer first
- Use the bare enum-variant shorthand for fls's own stdin sink

### Revert

- Undo every ?-chain tightening still unsafe under MSVC

## [0.52.1] - 2026-09-09

### Chore

- *(release)* Bump to 0.52.1

### Fix

- *(fls)* Resolve hover and dot-completion through an inline propagation receiver
- *(codegen)* Stop a stale hoist position from leaking across functions

### Fmt

- Fix an unformatted continuation line in navigation.fn

## [0.52.0] - 2026-09-09

### Chore

- *(release)* Bump to 0.52.0

### Docs

- Document transitive imports and global private-name uniqueness as intended

### Feat

- *(codegen)* Support a propagation as a bare fit subject
- *(fls)* Resolve a propagation used as a fit subject in hover/completion

### Fix

- *(codegen)* Dispatch a method on an indexed element reached through a chain
- *(parser)* Name the reserved word when it collides with a binding
- *(codegen)* Take the address of a call result or enum-variant shorthand
- *(codegen)* Let a method call resolve a global variable as its receiver
- *(parser)* Reject two adjacent expressions with no operator between them

### Test

- *(lexer)* Add regression coverage for the doubled-backtick escape
- *(typecheck)* Add regression coverage for the duplicate-symbol diagnostic

## [0.51.1] - 2026-09-09

### Chore

- *(release)* Bump to v0.51.1

### Fix

- Postfix ?/! failed to hoist under MSVC when used inline as a receiver
- *(codegen)* '{ptr}'/'{raw}' skip Display dispatch, showing the raw pointer
- Restore expr?.field inline-receiver and fix {ptr} MSVC dispatch
- *(warnings)* Normalize resolved import path before comparing against pos.filename
- Restore expr?.field inline-receiver and fix {ptr} MSVC dispatch (#112)
- *(editors)* Highlight postfix '?' as an operator, matching '!'

### Refactor

- Adopt postfix ?/! propagation across src/, where the shape matches exactly

### Revert

- Drop expr?.field inline-receiver support, real MSVC crash on Windows CI

## [0.51.0] - 2026-09-08

### Chore

- *(release)* Bump to v0.51.0

### Docs

- *(examples)* Add postfix ?/! propagation examples

### Feat

- *(lang)* Function values as first-class - checked at every call site, valid everywhere a type is
- *(lang)* Postfix ? and ! operators for Option/Result propagation

### Fix

- *(fls)* Switch stdio to binary mode on Windows to fix LSP framing
- *(fls)* Fix LSP header framing on Windows via runtime backend check
- *(codegen)* Infer generic type params from &arg and let-copied identifiers
- *(semantics)* Report missing_return and unused-const warnings at their own position; type-check top-level consts
- *(fls)* Sizeof/fork in completion, self. filtering, no completion inside comments
- *(fls)* Let-inferred function value hovers its own type, not the referenced function's declaration
- Postfix operator precedence after a method chain, private-method resolution, and formatter spacing
- Generic function call chaining, and postfix operators before another unary op

### Refactor

- *(lang)* Convert two real call sites to postfix ! propagation

## [0.50.4] - 2026-09-06

### Chore

- *(ci)* Drop the Windows -lm bootstrap bridge, no longer needed

### Fix

- *(installer)* Drop stale zig default from the Windows MSI and portable package
- *(fls)* Resolve a bare '.{...}' compound-literal shorthand field's own hover
- *(codegen)* Guard nil pointers in Display-dispatched varargs
- *(fls)* Render a generic type param's own declared constraint in hover
- *(codegen)* Increase MSVC test-binary stack from 8 MB to 64 MB

## [0.50.3] - 2026-09-05

### Chore

- *(release)* Bump to v0.50.3

### Fix

- *(codegen)* Resolve generic field types, FFI-narrowed let inference, and fls for-loop item hover
- *(cli)* Drop -lm on Windows, clang there links via lld-link, not a POSIX linker
- *(ci)* Bridge Windows past the old bootstrap binary's own -lm bug
- *(ci)* Check lib.exe's own exit code creating the stub m.lib
- *(ci)* Write the stub m.lib's bytes directly, lib.exe needs an input to produce one
- *(ci)* Build the stub m.lib from a real compiled object, not hand-rolled bytes
- *(ci)* Build fun and fls twice, so a release actually ships this checkout's own compiler behavior
- *(ci)* Call the just-built fun by path for the second build pass
- *(ci)* Run the second Windows build pass from a copy, not the running exe itself
- *(ci)* Make it a real 3-stage bootstrap, 2 stages didn't fully converge
- *(codegen)* Resolve the actual compiler for msvc-mode, and top-level consts in varargs

## [0.50.2] - 2026-09-04

### Build

- *(deps-dev)* Bump fast-uri
- *(deps-dev)* Bump fast-uri from 3.1.5 to 3.1.7 in /editors/vscode in the npm_and_yarn group across 1 directory (#103)
- *(deps)* Bump the npm_and_yarn group across 2 directories with 1 update
- *(deps)* Bump the npm_and_yarn group across 2 directories with 1 update (#104)

### Chore

- Drop leftover zig-out/zig-cache gitignore entries
- *(release)* Bump to v0.50.1

### Docs

- Document the per-test/per-fuzz-target commands, and fork in the async debugging notes
- Sweep stale Zig references and dead cross-links, link sections

### Feat

- *(codegen)* Emit #line directives for -g, restoring native debugging
- *(website)* Tabbed stdlib module view, syntax highlighting sourced from the editor themes
- *(website)* Split the docs into topic-based tabs, not two giant pages
- *(website)* Redesign the sidebar nav, drop the redundant right-side TOC

### Fix

- *(fls)* Infer more let shapes, generic literals/multi-param returns, and declaration type params
- *(fls)* Show a sized array's own size and fence a char literal's own hover breakdown
- *(fls)* A two-variable for loop over a Map binds key/value, not index/item
- *(fls)* Substitute a fit arm's own payload binding type, and resolve a call-shaped fit subject
- *(fls)* Escape a control-character literal's own hover, drop an unused import
- *(warnings)* Flag a fit's catch-all when both bin values are already covered
- *(fls)* Substitute a generic return through a compound-shaped parameter
- *(fls)* Give each outline field, variant, and quirk method its own position
- *(fls)* Prefer a method over a same-named field when the reference is a call
- *(typecheck)* Reject ambiguous enum shorthand and duplicate top-level names
- *(fls)* Resolve a fit arm's own payload binding through a let-inferred subject
- *(fls)* Return document symbols as a real nested tree, not a flat guess
- *(fls)* Nest a concrete-instantiation impl's own methods under its base compound too
- *(cli)* -test/-fuzz respect -no-exec, and -warn-unused-lenient actually works
- *(codegen)* Pin every line of an async/fork trampoline's own debug info
- *(cli)* -test/-fuzz also respect -outf/keep_c, update docs to match
- *(cli)* Merge manifest and -D defines everywhere, not just one or the other
- *(cli)* -ast prints under -test/-fuzz too, not just a plain compile
- *(cli)* Fun build respects -D too, not just fun.toml's own defines
- *(fls)* Resolve a quirk-typed receiver's method, a parenthesized chain, and a compound-literal field name
- *(fls)* Resolve a chain method whose own paren group ends in a dereferenced call
- *(fls)* Go-to-definition on a quirk-typed receiver's method lands on the method, not the quirk
- *(ci)* Make WiX Toolset available on PATH after choco install for aarch64 Windows
- *(website)* Fall back to fun.toml for the repo version, not just build.zig.zon
- *(website)* Stop double-boxing code blocks, add copy buttons, fix editor caret drift
- *(website)* Stabilize the doc-tab TOC across nav clicks, deep links, and scroll-spy
- *(website)* Mobile-native stdlib modal, fix duplicate doc titles
- *(ci)* Bootstrap release builds from the newest other release, not "latest"
- *(ci)* Fix PowerShell quote mangling, gate extension publish on release success
- *(ci)* Replace the retired macos-13 runner with macos-15-intel

### Inception

- Self-hosted Fun toolchain (#102)

### Test

- *(fls)* Lock in the fuzz block data/len hover behavior on inception

## [0.46.16] - 2026-09-03

### Docs

- Fix the C compiler selection docs, stale since self-hosting

### Feat

- *(fls)* Hover a number literal to see it in decimal, hex, binary, and octal

### Fix

- *(fls)* Resolve generic calls, arithmetic, await, and chains through parens in let-inference
- *(fls)* Give fun.toml's own PACKAGE_NAME/PACKAGE_VERSION hover and completion support
- *(cli)* Rename manifest's [[bin]] target to [[exe]]

### Refactor

- *(cli)* Rename the manifest's [[bin]] target to [[exe]]

### Test

- *(warnings)* Cover blocking_fork_deadlock, the one warning id with no test at all

## [0.46.15] - 2026-09-02

### Ci

- Bump test timeout-minutes 20 -> 35 for macOS

### Fix

- *(codegen)* Fix print() routing and qrecv/frame scoping bugs
- *(cli,codegen,tests)* Full MSVC support for FUN_CC=cl fun build

## [0.46.14] - 2026-09-01

### Chore

- *(ci)* Revert forced FUN_CC=cl on Windows build step

### Ci

- Drop the Force clang on Linux workaround
- Two-stage Windows build — bootstrap with clang then recompile with cl
- Load MSVC env before fun build on Windows

### Fix

- *(fls)* Rename SEVERITY_ERROR, it collides with a Windows SDK macro
- *(fls)* Remove a closed document from its map before freeing its uri
- *(codegen)* Stop relying on _BitInt for sized ints up to 128 bits
- *(codegen)* Dispatch Windows close() through _close before closesocket; the bare alias silently fails on pipe fds
- *(codegen,windows)* Comprehensive MSVC compatibility fixes for examples
- *(codegen,windows)* MSVC type-inference and multi-dim array iteration
- *(tests,windows)* Use cmd /c echo on Windows in the observe_probe test
- *(tests,windows)* Fix MSVC defaults in harness and add flicker reporter
- *(ci)* Avoid overriding FUN_STDLIB_DIR with POSIX $PWD on Windows runners
- *(ci)* Pin FUN_STDLIB_DIR to GITHUB_WORKSPACE stdlib on Windows test steps
- *(ci,codegen)* Use github.workspace template for Windows stdlib path and suppress void-wrapper C4098
- *(codegen)* Restore codegen.fn formatting via self-hosted formatter
- *(ci)* Set up MSVC before build step on Windows so fun.exe is MSVC-native
- *(lexer)* Strip \r from raw strings; add .gitattributes for LF checkout
- *(codegen)* Eliminate __auto_type and GNU statement expressions from generated C

### Fmt

- Run the formatter over files the lint step flagged

## [0.46.13] - 2026-08-25

### Feat

- *(fmt)* Wrap an over-long ||/&& chain, filling each line like fit arms
- *(cli)* Shorten fun init's project kinds to lib/exe/mix, and write a .gitignore

### Fix

- *(fls)* Stop the workspace symbol table from outliving a closed document's own strings
- *(codegen)* Rename TokenType, add a Windows clock_gettime, use dot-shorthand throughout
- *(stdlib)* Stop formatting a num with %lld, portable only by accident
- *(codegen)* Give the fork-scheduler's own prelude the clock_gettime shim too
- *(codegen)* Give Windows a real clock_gettime for std.channel's own deadline math
- *(codegen)* Guard the Windows clock_gettime shim from MinGW's own real one

## [0.46.12] - 2026-08-25

### Docs

- *(fls)* Document and test the deliberate refusal of a ranged edit with no baseline
- *(examples)* Exercise implicit-typed const bindings, not just explicit
- *(ci)* Update every remaining compiler/ reference to src/
- *(cli)* Document -test/-fuzz/-fuzz-target in help text

### Feat

- *(fls)* Completion offers a compound-init literal's own field names
- *(fls)* Completion offers a call snippet with a tab stop per parameter
- *(fls)* Sizeof shows a canned hover, matching fork's own treatment
- *(fls)* Completion items carry structured labelDetails
- *(fls)* Completion offers a generic type snippet with a tab stop per param
- *(fls)* Persistent, incrementally-maintained workspace symbol table
- *(fls)* Semantic tokens mark a stdlib reference with the defaultLibrary modifier
- *(fls)* Add textDocument/documentHighlight
- *(fls)* Add textDocument/foldingRange
- *(fls)* Add textDocument/selectionRange; fix defaulted-param hover, nested-fit resolution, and unmet-expect diagnostics
- *(fls)* A quirk's own code lens shows implementation count, not a name-matched reference count
- *(fls)* Add textDocument/callHierarchy; fix a defaulted parameter's own digits leaking into inlay hints and completion snippets
- *(compiler)* Static format-string checking for printf and format()
- *(fls)* Add textDocument/documentLink; fix an import alias resolving to nothing at its own use sites
- *(fmt)* Wrap an over-long fit arm's own conditions, filling each line rather than leaving it on one
- *(fls)* Recognize C builtins the language accepts without a declaration, in hover, go-to-definition, and completion
- *(fls)* Check exhaustiveness on a fit receiving from a channel
- *(fit)* Non-exhaustive fit warning and its codeAction name every missing variant at once
- *(fls)* Watch .fn files on disk instead of only re-reading them on next access
- *(time)* Millisecond-precision sleep
- *(json)* Free a parsed JsonValue's own owned data
- *(stdlib)* Add a Clonable quirk, implemented by Vec, Map, and Set
- *(cli)* Add fun init to scaffold a new package
- *(cli)* Report the compiler's own version, not a cwd manifest's
- *(cli)* Fall back across C compilers, and support FUN_CC_ARGS
- *(cli)* Inject PACKAGE_NAME/PACKAGE_VERSION into fun build targets

### Fix

- *(codegen)* A plain function/method prototype splices safely while nested
- *(fls)* Positions convert between LSP's UTF-16 columns and byte columns
- *(fls)* A let-inferred receiver resolves its own methods, diagnose caches per revision
- *(fls)* DidClose publishes empty diagnostics to clear the editor's gutter
- *(fls)* Stdlib namespace hover resolves every path depth
- *(fls)* A generic method on a let-inferred receiver specializes correctly
- *(fls)* Definition_workspace_wide respects cross-file pub visibility
- *(fls)* A fit arm's payload binding resolves when the subject is a field access
- *(fls)* Completion offers a fit arm's own payload binding
- *(fls)* A fit arm's payload binding resolves to a tighter position
- *(fls)* A local declared inside an elif branch resolves
- *(fls)* A local inside defer{} resolves, and stop hand-listing body-carrying statement kinds four times
- *(fls)* A fit's own bare variant hover substitutes the subject's concrete generic args
- *(fls)* Hover's See also footer never links a cross-file type that isn't pub
- *(fls)* A fit's dot-shorthand hover resolves inside a test/impl/fuzz block and against a let-inferred subject
- *(fls)* Semantic tokens distinguish primitive vs declared type, enum variant, and const correctly
- *(fls)* A variant's own tag value shows hovering its declaration, not just a use site
- *(fls)* A bare variant shorthand resolves outside a fit/ret too; code lens covers types, skips main/methods, and its click actually works
- *(fls)* A for loop's own bound variables resolve in hover/completion; workspace/symbol gets a real scored fuzzy match
- *(fls)* Completion distinguishes kinds instead of showing everything as Variable, and resolves an alias even while the document doesn't parse
- *(fls)* Dot-completion on an enum, its own name or an instance, lists variants instead of falling back to the whole file
- *(fls)* Dot-completion scopes to a receiver's own declared type even while the document does not parse
- *(fls)* Completion distinguishes kinds instead of showing everything as Variable, and resolves an alias even while the document doesn't parse
- *(fls)* Dot-completion on an enum, its own name or an instance, lists variants instead of falling back to the whole file
- *(fls)* Dot-shorthand completion covers a field-access fit subject, its own name or an instance, lists variants instead of falling back to the whole file
- *(fls)* Dot-shorthand completion scopes to a receiver's own declared type even while the document does not parse
- *(fls)* Hover and inlay hints show a let-inferred local's own concrete generic type, not just the bare template
- *(fls)* Dot-shorthand completion covers a call argument and a field-access comparison/assignment operand, even while the document does not parse
- *(fls)* Hover and go-to-definition resolve a name to the actually-declared symbol, not an unrelated compound field or enum variant sharing it
- *(fls)* Hover and inlay hints show a let-inferred local's own concrete generic type, not just the bare template
- *(fls)* Semantic tokens classify a C builtin correctly, not by its own naming-convention guess
- *(compiler)* Fit_non_exhaustive checks chr, str, and dec subjects, not just num and pointers
- *(fls)* Completion abbreviations (mainio, vecnew, ...) work even while the document does not parse; add mapnew, fito, and skeletons for fuzz and asm
- *(fls)* Dot-shorthand completion recognizes a channel receive's own fit subject too
- *(fls)* An impl method's own pub/private carries through, not hardcoded visible
- *(codegen)* A lazily-hoisted C prototype only skips re-emitting when it's actually still in scope
- *(codegen)* Stop copying the whole generated file just to check one byte
- *(fls)* Free a document's own parse tree instead of leaking it on every edit
- *(fls)* Free every outgoing response's own JSON text after it's written
- *(fls)* Json_quote writes into the caller's own builder instead of returning an owned string
- *(fls)* Deep-clone nodes pulled from the import cache instead of sharing them
- *(fls)* Free write_message's own wire buffer and every Item field
- *(fls)* Free remaining leaked format()/format_num() results, fix URI percent-encoding
- *(codegen)* Free a variadic function's own vargs array and owned varargs
- *(string)* Free StringBuilder's own buffer in build(), not just its output
- *(parser)* Free a scope when it's popped, not never
- *(fls)* Keep a pointer star when a let-inferred type ends a chain
- *(parser)* Deep-free tokens and ParseState's own scratch where nothing aliases them
- *(fls)* Free render_type/render_function_named's own owned return values
- *(fls)* Free render_type/render_function/_call_snippet results in completion
- *(fls)* Classify fork as a keyword, not an identifier, in semantic tokens
- *(process)* Strip memory-debugging env vars before spawning a child
- *(fmt)* Don't misformat a non-pub type's own generic brackets as comparisons
- *(fls)* Free the rest of the un-freed-render/build-result leaks
- *(fls)* Free the two deliberately-deferred ParseState scratch sites
- *(parser)* Free parse_program_cached's own scratch, including preloaded tokens
- *(codegen)* Give a fit-arm binding its DataType so for-each resolves the right element type
- *(fls)* Resolve free() to std.c.mem inside a same-named method, and hover on a dereferenced fit subject
- *(fls)* Keep Documents' own copies of URI/text rather than aliasing a request's freed message
- *(fls)* Stop json_quote_into recomputing len() every iteration
- *(fls)* Stop the diagnostics parse from mutating the cache's own tokens
- *(codegen)* Free StringBuilder.peek() results in the hoist-splice paths
- *(fls)* Free the transport's own per-message scratch
- *(fls)* Free replace_char's own result in path normalization
- *(fls)* Stop leaking scratch strings across symbols.fn's own helpers
- *(fls)* Free _candidate_type_names' own scratch in the hover footer
- *(semantics)* Free every Checker field, and each FnSig/CompoundInfo's own scratch
- *(semantics)* Free Analysis's own enum_variants/functions/compound_decls/local_types/channel_element_types
- *(fls)* Free DiagnosticsCache's own stale entry before replacing or dropping it
- *(ci)* Re-assert FUN_STDLIB_DIR at every fun invocation, not just the job env
- *(fls)* Resolve a for-each loop's own item type over a raw array, not just Vec<T>
- *(typecheck)* Give str[i] a real chr type instead of unknown
- *(fls)* Resolve name[i]'s own indexed type in let-inference, not the base's
- *(fls)* Stop a compound-init literal's own type name mis-rendering as "compound"
- *(cli)* Close CLI parity gaps against the Zig main compiler
- *(codegen)* Resolve a call embedded mid-chain when lowering method calls

### Refactor

- Rename compiler/ to src/

### Test

- *(fls)* Verify dot-completion merges a method from a different file

## [0.46.11] - 2026-08-19

### Feat

- *(fls)* Add workspace/symbol
- *(fls)* Hover and go-to-definition on an import path segment
- *(fls)* Add textDocument/inlayHint
- *(fls)* Add textDocument/codeAction
- *(fls)* Specialize a generic method's signature against its receiver
- *(fls)* Fill in a fit's missing arm, and read doc comments from imported files
- *(fls)* Implement the quirk-method-stub code action
- *(fls)* Add insert-await and mark-async code actions
- *(fls)* Add import-path completion, fix method hover/as-doc bugs
- *(fls)* Add hover's 'See also' related-types footer
- *(fls)* Add allow/expect warning-id completion
- *(fls)* Hover documents sized integer types (i7, u23, ...)
- *(fls)* Parameter-name inlay hints at call sites
- *(fls)* Hovering a constant shows its own literal value
- *(fls)* Add semanticTokens/full, fix a real lexer end-column bug
- *(fls)* Workspace-wide indexing for references and workspace/symbol
- *(fls)* Definition falls back to a workspace-wide type search

### Fix

- *(fmt)* Free the pre-grouped token vector after grouping
- *(fls)* Resolve a dotted chain through its own receiver's type
- *(warnings)* Register a function's own parameters as fit subjects
- *(editors)* Stop generic-type highlighting from matching comparisons
- *(fls)* Field/variant go-to-def, See also on containers, '..' import hover
- *(fls)* Resolve locals/params inside impl methods, add typeDefinition
- *(fls)* Let-hint gaps for char literals, field reads, bare copies
- *(fls)* Method-at-declaration hover, doc-comment prose left-trim
- *(fls)* Fit-arm locals, See-also container on bare variants, scope completion
- *(fls)* Resolve locals and params inside test and fuzz blocks
- *(fls)* Call-ending chains resolve everywhere, fix an .Impl regression
- *(fls)* De-mangle a quirk-conforming impl's own method name correctly
- *(fls)* TypeDefinition resolves a method call's own return type
- *(stdlib)* StringBuilder leaks a fragment on every append

### Test

- *(fls)* Cover a multi-dot ('....') parent-traversal import
- *(fls)* Use the raw-string doubled-backtick escape, not string concat

## [0.46.10] - 2026-08-16

### Feat

- *(fls)* Hover and go-to-definition for enum variants and fit payload bindings
- *(fls)* Add textDocument/signatureHelp

### Fix

- *(codegen)* Splice lazy prototypes at function scope, not block scope
- *(ci)* Pass a token to setup-fun so it doesn't hit the anonymous API limit
- *(codegen)* Give a plain method and a same-named quirk method separate identities
- *(codegen)* Ensure a by-value generic-field substitution's plain type is emitted first
- *(fls)* Stop mangling non-ASCII bytes into invalid JSON escapes
- *(fls)* Hover/definition for methods, qualified variants, doc comments, missing keyword docs
- *(fls)* Method hover was still returning null, and resolve generic variant payloads to concrete types
- *(codegen)* Give Windows thread/process compat a real pid_t and clock

### Merge

- Bring in the cli.fn -- pointer-comparison fix from main (v0.46.9)

## [0.46.9] - 2026-08-16

### Ci,docs

- Add self-hosted CI validation, describe Fun as self-hosted

### Docs

- Describe the directory-wide fun test/fuzz forms and env_or

### Feat

- *(selfhost)* Finish self-hosting, retire the Zig toolchain

### Fix

- *(ci)* Make the asm-arch check bootstrap-safe, lint with the built binary
- *(codegen)* Splice a nested generic method's own prototype at file scope
- *(codegen)* Drop redundant parens on if/while conditions, define Windows pid_t
- *(stdlib)* Compare -- by content, not pointer, in cli_parse_ext

## [0.46.8] - 2026-08-15

### Feat

- *(selfhost)* Run every test block under a directory, not just one file
- *(selfhost)* Port fuzz-mode codegen and the fun fuzz subcommand
- *(stdlib)* Process spawn/kill/sleep primitives, fix a real env() crash

### Fix

- *(selfhost)* Give kill() a real Windows implementation
- *(codegen)* Include windows.h before the new sleep helper uses Sleep
- *(codegen)* Give kill() a real Windows implementation

## [0.46.7] - 2026-08-15

### Docs

- Describe the elastic scheduler pool and Mutex/WaitGroup safety

### Feat

- *(cli)* Run every test/fuzz block under a directory, not just one file

### Fix

- *(selfhost)* Elastic scheduler pool, bounded concurrent import preload

## [0.46.6] - 2026-08-15

### Feat

- *(codegen)* Check format()'s argument count against its placeholders
- *(parser,codegen)* Parse and emit inline assembly (asm statement)

### Fix

- *(codegen)* Include time.h explicitly, close std.c.* header gap
- *(concurrency)* Elastic scheduler pool, eager Mutex/CondVar init, guarded WaitGroup count

### Merge

- Bring in the top-level statement-termination fix from main

### Test

- *(selfhost)* Close statement-termination gap note
- *(selfhost)* Close the last gap marker

## [0.46.5] - 2026-08-15

### Fix

- *(parser)* Require a trailing ';' on a bare top-level expression

### Merge

- Bring in the worker-thread stack-size fix from main (v0.46.4)

## [0.46.4] - 2026-08-15

### Docs

- *(tests)* Correct what the generic-compound-quirk gap actually is
- Drop -- asides from this session's own comments
- *(selfhost)* Close deep-expression stack-guard gap note

### Feat

- *(parser)* Measure a pointer type with sizeof
- *(typecheck)* Hold a global and a field to what their file offers
- *(parser)* Forward-reference a type in a compound initializer
- *(codegen)* Drive 'for x : c' via a user Iterator quirk impl

### Fix

- *(typecheck)* Tell two instantiations of a generic apart
- *(typecheck)* Refuse to compare two different enums
- *(typecheck)* Reject sizeof of a name nothing declares
- *(codegen)* Fill a defaulted argument correctly at every call
- *(codegen)* Substitute a generic enum's self-referential payload
- *(codegen)* Coerce a value reached through an index or a field
- *(codegen)* Let a method chain onto a quirk-typed call result
- *(codegen)* Dispatch through a quirk-typed array element, and coerce a plain assignment
- *(codegen)* Give a plain compound's fixed-size array field its brackets
- *(codegen)* Bound a hex string escape to two digits
- *(typecheck)* Reject an empty enum and let-from-void
- *(codegen)* Dispatch a generic compound's quirk impl dynamically
- *(codegen)* Inline a fixed-size array field on a generic compound
- *(warnings)* Warn on a non-exhaustive num/pointer fit with no catch-all
- *(codegen)* Replay a loop-body defer before continue and break
- *(codegen)* Resolve a fit's generic-call subject return type
- *(typecheck)* Reject a required parameter after a defaulted one
- *(codegen)* Agree on the extra star an array return type needs
- *(codegen)* Materialize a quirk dispatch's call-result receiver once
- *(codegen)* Dot-vs-arrow after indexing a raw pointer, array-literal call args
- *(codegen)* Reject a genuine by-value compound cycle
- *(codegen)* Substitute a method's own type param, not the impl's
- *(codegen)* Monomorphize a generic async/fork call target
- *(codegen)* Size every worker thread's stack explicitly

### Test

- *(selfhost)* Read a float literal written with an exponent
- *(selfhost)* Run the quirk coercion shapes as real tests
- *(fit)* Close all remaining fit_tests.fn gap markers

## [0.46.3] - 2026-08-14

### Feat

- *(typecheck)* Reject a written zero divisor and a mismatched fit branch

### Fix

- *(typecheck)* Enforce a method's own generic bound
- *(typecheck)* Judge visibility on an alias-qualified call
- *(stdlib)* Read the exponent in a decimal

### Test

- *(selfhost)* Run the last test that was only described

## [0.46.2] - 2026-08-14

### Build

- Declare fls as a binary the manifest builds

### Docs

- *(tests)* Say why the watchdog test is still waiting

### Feat

- *(fls)* Report diagnostics, hover, and go to definition
- *(fls)* List what a document declares
- *(fls)* Find references, rename, and complete
- *(fls)* Format a document, and complete with snippets
- *(codegen)* Carry a function-typed argument through an async call

### Fix

- *(lexer)* Let a raw string hold a backtick
- *(imports)* Ask where the standard library is rather than assume
- *(selfhost)* Drop imports nothing uses
- *(warnings)* Judge a real file the way the reference does
- *(typecheck)* Say when a call names a method a type does not have
- *(warnings)* Check a fit written in shorthand
- *(codegen)* Let a program name a variable argv
- *(codegen)* Give Windows a setenv of its own

### Perf

- *(fls)* Read a document once per revision
- *(fls)* Parse an unchanged import once, not once per keystroke

### Test

- *(selfhost)* Write the tests that were left unwritten
- *(selfhost)* Run the programs whose behavior was only asserted about
- *(selfhost)* Hand back what a run produced, not only its output

## [0.46.1] - 2026-08-13

### Fix

- *(lexer)* Let a raw string hold a backtick

## [0.46.0] - 2026-08-13

### Feat

- *(stdlib)* Sections, flags, directories, sink reads, and hexadecimal

## [0.45.5] - 2026-08-13

### Feat

- *(semantics)* Follow the arguments an instantiation supplies
- *(semantics)* Check instantiations, inferred ones included
- *(semantics)* Report what a program probably did not mean
- *(semantics)* Notice races, deadlocks, overflows, and out-of-range literals
- *(semantics)* Hold a name to what the file declaring it offers
- *(fls)* Speak the language server protocol

### Fix

- *(parser)* Leave no value pointer unset on a declaration that has none
- *(warnings)* Count a variant constant as using the enum's import

### Refactor

- *(io)* Let a sink read as well as write
- *(fls)* Name the stream at the call rather than binding it first

## [0.45.4] - 2026-08-12

### Feat

- *(semantics)* Check calls made through a receiver
- *(semantics)* Check impl bodies, quirk conformance, and enum values
- *(semantics)* Reject unknown callees, value sizeof, and non-bin conditions
- *(semantics)* Hold generic calls and quirk impls to what they declare

### Fix

- *(codegen)* Stop reading past the end of a mangled name

## [0.45.3] - 2026-08-12

### Fix

- *(codegen)* Keep an element's pointer depth in the iterator's option type
- *(cli)* Build a manifest from a given directory

### Style

- Run zig fmt over the cli tests

## [0.45.2] - 2026-08-12

### Feat

- *(cli)* Start the formatter, emitting from the token stream
- *(cli)* Teach the formatter literals, prefix operators, and brackets
- *(cli)* Keep literals, fenced comments, and multi-statement blocks intact
- *(cli)* Keep compound literals inline and indent continuation lines
- *(cli)* Match the reference formatter's line and comment layout
- *(cli)* Reproduce asm statements and align trailing comments
- *(cli)* Normalize block braces instead of copying their spacing
- *(cli)* Lay out unformatted source instead of reproducing it
- *(cli)* Format from the command line
- *(semantics)* Check types before generating code

### Fix

- *(lexer)* Record whether whitespace follows a token
- *(lexer)* Keep whitespace that a lookahead consumed
- *(cli)* Write character literals as they were written
- *(imports)* Keep an absolute path absolute
- *(codegen)* Keep a field receiver's type arguments when chaining

### Test

- *(fmt)* Cover the formatter with its own cases

## [0.45.1] - 2026-08-12

### Feat

- *(cli)* Read fun.toml with library, binary, and mixed packages
- *(stdlib)* Parse TOML sections and arrays of tables
- *(cli)* Compile and run programs, with build-time constants from the manifest
- *(cli)* Build a package from its manifest
- *(cli)* Run a file's test blocks with fun test
- *(codegen)* Back the process bindings on Windows

### Fix

- *(cli)* Build and run the same way on all three platforms
- *(cli)* Drop an unused import
- *(codegen)* Name the node a failed compile choked on, and accept warning control
- *(codegen)* Give a test body its own function state, and report where a failure came from
- *(cli)* Keep build output under fun-out, and stop tracking generated C
- *(fmt)* Keep a raw string's contents out of comment alignment

## [0.45.0] - 2026-08-12

### Build

- *(deps-dev)* Bump js-yaml
- *(deps-dev)* Bump js-yaml from 4.2.0 to 4.3.1 in /editors/vscode in the npm_and_yarn group across 1 directory (#101)

### Chore

- *(deps-dev)* Bump the npm_and_yarn group across 1 directory with 2 updates
- *(deps-dev)* Bump the npm_and_yarn group across 1 directory with 2 updates (#96)
- *(deps)* Bump the npm_and_yarn group across 2 directories with 2 updates
- *(deps)* Bump the npm_and_yarn group across 2 directories with 2 updates (#97)
- *(deps)* Bump brace-expansion
- *(deps)* Bump brace-expansion from 5.0.8 to 5.0.9 in /editors/vscode in the npm_and_yarn group across 1 directory (#99)
- *(deps-dev)* Bump the npm_and_yarn group across 1 directory with 2 updates
- *(deps-dev)* Bump the npm_and_yarn group across 1 directory with 2 updates (#100)

### Ci

- Bump test step timeout to 20 minutes

### Docs

- *(self-hosting)* Clarify why array-typed generic args stay deferred
- *(self-hosting)* Refresh stale doc comments across parser.fn
- Document testing/fuzzing, fix stale Result<T,E> references
- *(fuzz)* Document the compiler fallback list and FUN_FUZZ_NO_ASAN
- *(fuzz)* Document engine-flag passthrough via --
- *(fuzz)* Document FUN_FUZZ_CC and the Windows caveat
- Document const bindings, update editor grammars and examples
- *(examples)* Add examples for language features added during self-hosting
- *(selfhost)* Trim codegen.fn comments to short, current-state, plain-case style (partial)
- *(selfhost)* Trim more codegen.fn comments to short, current-state, plain-case style (partial)
- *(stdlib)* Trim math/sync/path/set/time/toml/array comments to short, current-state, plain-case style
- *(stdlib)* Trim channel/string/vec/map comments to short, current-state, plain-case style
- *(stdlib)* Trim io/log/fs/json/net comments to short, current-state, plain-case style
- *(stdlib)* Trim remaining stdlib file comments to short, current-state, plain-case style
- *(selfhost,stdlib)* Trim remaining comments to short, current-state, plain-case style; strip Usage-block headers from stdlib
- *(selfhost)* Trim typedefs/expressionable_defs/parse_state/datatype_defs comments to short, current-state, plain-case style
- *(selfhost)* Trim parser.fn comments to short, current-state, plain-case style
- *(selfhost)* Finish trimming codegen.fn comments to short, current-state, plain-case style
- *(selfhost)* Strip remaining regression-test/fix-narration framing from codegen.fn test comments
- *(selfhost)* Tighten overlength ast.fn/import_resolver.fn comments to short Rust-style prose
- *(stdlib)* Collapse Params/Returns/Notes doc-comment boilerplate to short prose in io/log/fs/json/net
- *(stdlib)* Collapse Params/Returns/Notes doc-comment boilerplate to short prose in math/sync/path/set/time/toml/array/c-math/c-io/runtime_backend
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(stdlib)* Collapse Params/Returns/Notes doc-comment boilerplate to short prose in remaining stdlib files
- *(selfhost,stdlib)* Drop double-dash asides, self-referential headers, and redundant language-name mentions from comments
- *(selfhost)* Tighten overlength parser.fn comments to short Rust-style prose (partial)
- *(stdlib)* Collapse Params/Returns/Notes doc-comment boilerplate to short prose in vec/map
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength codegen.fn comments to short Rust-style prose
- *(selfhost)* Replace remaining double-dash asides in codegen.fn comments
- *(selfhost)* Tighten overlength parser.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength parser.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength parser.fn comments to short Rust-style prose (partial)
- *(selfhost)* Tighten overlength parser.fn comments to short Rust-style prose

### Feat

- *(self-hosting)* Process spawning stdlib, contextual fork, T[] return types
- *(self-hosting)* Add directory operations to std.fs
- *(self-hosting)* Add panic("msg") as a return-type-polymorphic expression
- *(self-hosting)* First-class function parameters, Vec.sort_by, std.ctype
- *(self-hosting)* Add test blocks and `fun test` (Phase 0.5)
- *(self-hosting)* Add fun.toml manifest and `fun build` (Phase 0.5)
- *(self-hosting)* Port modules/lexer to Fun, fix real compiler/fls bugs found along the way
- *(self-hosting)* Add test coverage for the lexer, fix a real (A||B)&&C codegen miscompilation
- *(self-hosting)* Port modules/ast to Fun, fix two formatter pointer-spacing bugs
- *(self-hosting)* Port modules/semantics, add doc comments across selfhost/
- *(self-hosting)* Begin modules/parser port, fix four latent compiler bugs found along the way
- *(self-hosting)* Port parse_datatype/parse_generic_type_args to the self-hosted parser
- *(self-hosting)* Port parse_single_token_to_node to the self-hosted parser
- *(self-hosting)* Port operator-precedence reordering to the self-hosted parser
- *(self-hosting)* Port operator-precedence reordering to the self-hosted parser
- *(self-hosting)* Port unary operators to the self-hosted parser
- *(self-hosting)* Port statement/body/variable-declaration parsing to the self-hosted parser
- *(self-hosting)* Port ret/assert statement parsing to the self-hosted parser
- *(self-hosting)* Port if/elif/else statement parsing to the self-hosted parser
- *(self-hosting)* Port function declaration parsing to the self-hosted parser
- *(self-hosting)* Port for-loop statement parsing to the self-hosted parser
- *(self-hosting)* Port enum-variant shorthand (.Variant) expression parsing
- *(self-hosting)* Port fit-statement parsing (non-destructuring patterns)
- *(self-hosting)* Port for-loop range/iterator forms
- *(self-hosting)* Port generic type params and variadic args into parse_function
- *(self-hosting)* Port a top-level parse loop (parse/parse_top_level_declaration)
- *(self-hosting)* Port imp (import statement) syntax parsing
- *(self-hosting)* Port break/continue/defer statements and test declarations
- *(self-hosting)* Port compound and enum declaration parsing
- *(self-hosting)* Port quirk (structural interface) declaration parsing
- *(self-hosting)* Port impl (quirk implementation / type methods) parsing
- *(self-hosting)* Port array-bracket type support (parse_array_brackets)
- *(self-hosting)* Port fit-statement destructuring patterns
- *(self-hosting)* Port nil/panic/await/fork/channel ops/warning-control
- *(self-hosting)* Port compound-literal init, array indexing/literals
- *(self-hosting)* Port first codegen slice (literals, ret, plain fun)
- *(self-hosting)* Extend codegen with identifiers, unary/binary exprs, variables, if/elif/else
- *(self-hosting)* Codegen support for function calls and parameters
- *(self-hosting)* Codegen support for for-loops and expression statements
- *(self-hosting)* Support user-defined-type bare variable declarations
- *(self-hosting)* Codegen support for compounds and field access
- *(self-hosting)* Codegen support for impl methods and method calls
- *(self-hosting)* Codegen support for Vec iterator for-loops
- *(self-hosting)* Codegen support for fit pattern matching
- *(self-hosting)* Codegen support for plain enums
- *(self-hosting)* Codegen support for tagged-union enums
- *(self-hosting)* Codegen support for fit pattern matching over enums
- *(self-hosting)* Codegen support for bare enum-variant shorthand
- *(self-hosting)* Codegen support for chained field access
- *(stdlib)* Widen Result<T> to Result<T, E> for custom error types
- *(self-hosting)* Codegen support for a fit statement over *self/chained subjects
- *(self-hosting)* Codegen support for bare enum-shorthand in assignments
- *(self-hosting)* Codegen support for quirk-implementing impls
- *(self-hosting)* Codegen support for generic compound monomorphization
- *(testing)* Rewrite the test-mode runner to run concurrently, in Fun
- *(editor)* Per-test Run/Debug CodeLens buttons above test blocks
- *(testing)* Add std.mock_time -- a Clock quirk for time-mocked tests
- *(parser)* Add fuzz "name" (data, len) { ... } declaration syntax
- *(fuzz)* Compile fuzz blocks into a harness for fun -fuzz / fun fuzz
- *(fuzz)* Wire fun -fuzz / fun fuzz to actually build and run
- *(editor)* Add a Fuzz CodeLens button above fuzz blocks
- *(self-hosting)* Add a fuzz target for the self-hosted lexer
- *(self-hosting)* Parser support for bare generic-type variable decls
- *(self-hosting)* Codegen support for generic enum monomorphization
- *(self-hosting)* Codegen support for generic impl method monomorphization
- *(self-hosting)* Codegen support for fit over a receiver.method() call subject
- *(self-hosting)* Multi-file import resolution and merging
- *(self-hosting)* Parser + codegen support for function-type parameters
- *(self-hosting)* Parser support for fuzz declarations; fix std.* import resolution
- *(self-hosting)* Resolve bare enum shorthand in an equality comparison's RHS
- *(self-hosting)* Array indexing, nil literal, and break/continue statements
- *(self-hosting)* Method calls through a chained field-access receiver
- *(self-hosting)* Codegen support for panic(msg) expressions
- *(self-hosting)* Resolve bare enum shorthand in a plain-function call argument
- *(self-hosting)* Generic function monomorphization
- *(self-hosting)* Let-declaration type inference (bounded, best-effort)
- *(self-hosting)* Generic impl method rtype tracking + fit-binding locals
- *(self-hosting)* Nested generic instantiation support
- *(self-hosting)* Contextual type-param inference for generic function calls
- *(self-hosting)* Codegen support for assert statements
- *(self-hosting)* Parse a builtin type keyword as a sizeof(...) operand
- *(self-hosting)* Codegen support for compound-literal initializers
- *(self-hosting)* Codegen support for defer statements
- *(self-hosting)* Structural local-type tracking, chained-receiver fixes
- *(self-hosting)* Cross-file compound visibility, field-access for-each, structural compound-field types
- *(lang)* Add const bindings, explicit generic call syntax, fix codegen bugs
- *(self-hosting)* Migrate to explicit fuzz param types and generic ok<T,E>
- *(self-hosting)* First end-to-end compiler driver + 2 codegen fixes
- *(lang)* Add backtick raw string literals
- *(selfhost)* Port the compiler's own thread primitive to codegen.fn
- *(selfhost)* Port the no-fork deadlock watchdog to codegen.fn
- *(selfhost)* Port `const` declarations
- *(selfhost)* Port async/await codegen
- *(selfhost)* Port fork/scheduler codegen; fix a top-level const ordering bug
- *(selfhost)* Port varargs support, directory-iteration helpers, and fix stale hoist-position bugs
- *(selfhost)* Support array-literal initializers and raw-array for-iteration
- *(selfhost)* Port quirk dynamic dispatch through an abstract quirk-typed value
- *(selfhost)* Monomorphize a method's own generic type param, combined with the impl's
- *(selfhost)* Resolve calls/access through an aliased import
- *(selfhost)* Fill in omitted trailing default-parameter arguments
- *(selfhost)* Set/Map Iterator-protocol for-each, plus Vec expression-iterable materialization
- *(selfhost)* Await on a quirk-typed receiver, plus pointer-deref/paren chain support
- *(selfhost)* Sizeof(Generic<T>), generic-function pointer-arg inference, self-referential generic compound/enum crash
- *(selfhost)* Concrete generic-quirk instantiation as a type (To<T>/From<T>)
- *(selfhost)* Derive a generic quirk's vtable from its own declaration, not just a concrete impl
- *(selfhost)* The compiler now compiles itself (#98)

### Fix

- *(fls)* Index locals inside test { } blocks
- *(fls)* Unused-function false positive for test-only helpers, formatter unary-! after assert
- *(fls)* Empty inline fit-arm body spacing, add WarningId's From<str>, trace import-resolution debug logs to their triggering LSP method
- *(fls)* Resolve a file's imports once per inlayHint request, not once per call site
- *(lexer)* Preserve 0x/0b prefix position when -fmt reformats hex/binary literals
- *(codegen)* Support any Vec-typed expression in for-each loops
- *(codegen)* Resolve Fun/libc symbol clashes correctly; clean up C output
- *(stdlib)* Zero out Option/Result unwrap fallback; RFC3339 UTC log timestamps
- *(fls)* Self hover pointer type, default-param hover, enum completion narrowing
- *(self-hosting)* Support bare-datatype-keyword variable declarations in statement position
- *(fmt)* Don't treat test-block bodies as declaration context
- *(self-hosting)* Bound a unary operand at a following binary operator
- *(fls)* Fix out-of-bounds crash during workspace indexing, bound auto-restarts
- *(fmt)* Correct decl/enum-block depth tracking and pointer-star spacing
- *(codegen)* Exclude bound generic type params from sizeof visibility check
- *(fls)* Correct nested-generic type truncation and an OOB panic in indexing
- *(codegen)* Support function-typed parameters on async functions
- *(fls)* Index fuzz blocks' data/len params as typed locals
- *(fuzz)* Make it actually work cross-platform, fix a real C bug
- *(fmt)* Keep a space between a fuzz block's name string and its params
- *(fuzz)* Use a dedicated FUN_FUZZ_CC, not the shared FUN_CC
- *(self-hosting)* Parser accepts a unary-prefixed RHS after a binary operator
- *(self-hosting)* Hoist a generic instantiation triggered from a compound/enum's OWN field too
- *(self-hosting)* Crash when a generic function's own return type needs nested monomorphization
- *(self-hosting)* Two real bugs in nested generic monomorphization
- *(fls)* Const-aware indexing and several hover/goto-def correctness bugs
- *(fls)* Resolve hover for a dot-shorthand nested in an enum constructor call
- *(fls)* Hover shows const bindings distinctly from plain variables
- *(fls)* Resolve cross-file dot-shorthand hover for a plain enum variant
- *(fls)* Resolve cross-file hover for a plain enum variant with no payload
- *(fls)* Resolve hover for function-type parameters at declaration site
- *(fls)* Defer full-workspace scan until references/workspace-symbol need it
- *(codegen)* Include windows.h for dir-iteration Win32 API types
- *(codegen,fls)* Fix remaining Windows-only test failures
- *(cli,docs)* Mute test-mode compiler-error noise, fix stale fuzz docs
- *(fls)* Resolve dangling-pointer crash and cross-file fit-binding hover
- *(selfhost)* Fix multi-default-param and array-bracket-type parsing gaps
- *(selfhost)* Fix codegen bugs found by actually compiling+linking generated C
- *(selfhost)* Force a concrete monomorphizing impl's own type to instantiate early
- *(fls)* Fix hover truncating a nested generic field's type to its base name
- *(selfhost)* Substitute a generic compound field whose OWN type is nested-generic
- *(selfhost)* Resolve an explicit EnumName.Variant fit-arm against a generic subject
- *(selfhost)* Preserve structural generic args through type-param substitution
- *(selfhost)* Resolve method-call bare-shorthand args and support fit-await subjects
- *(selfhost)* Lazily emit plain compound/enum bodies in dependency order, fix generic pointer-depth undercounting
- *(selfhost)* Emit generic impl methods lazily, per call, instead of blindly on instantiation
- *(parser,selfhost)* Enforce impl type-param constraints, fix a unary-deref/comma parser bug and a hoist-position crash
- *(lexer,selfhost)* Correct token position tracking after whitespace, forward-declare plain functions/methods
- *(fls,selfhost)* Fix hover doc-comment bugs and 11 stage-2 self-compile blockers
- *(selfhost)* Port __fun_key_eq/__fun_key_hash intrinsics and missing prelude helpers
- *(selfhost)* Fix stale hoist-position locals and a nested generic-function draining bug
- *(selfhost)* Recognize a concrete impl's own self-type as a generic instantiation, achieving a zero-error stage-2 compile
- *(tests)* Stop double-delete failures in codegen_test.zig's own cleanup
- *(selfhost)* Fix two varargs bugs, achieve byte-identical self-hosting fixed point
- *(codegen)* Check ALL matching impls' constraints, not just the first
- *(selfhost)* Include <limits.h> in the prelude unconditionally
- *(selfhost)* Quirk return coercion, math.h, and several let-inference gaps
- *(selfhost)* Generic-method defaults, enum-arg inference, unique fit-subj temps
- *(selfhost)* Include POSIX/Windows socket headers unconditionally
- *(selfhost)* Resolve a qualified enum-variant access against the mangled instantiation
- *(selfhost)* Set expected_compound_type for a Variable declaration's own initializer
- *(selfhost)* Resolve bare-shorthand default values, avoid math.h/log() collision
- *(selfhost)* Suspend current_stmt_start_pos in resolve_field_chain's call-as-receiver swap
- *(selfhost)* Correct root-position sync for multi-level chained receiver hoists
- *(selfhost)* Generalize hoist-scratch nesting to all private-scratch swap sites
- *(selfhost)* Resolve compound-init's own bare template name against the active generic instantiation
- *(selfhost)* Pointer-dereference unary didn't continue parsing after its operand
- Quirk impl method prototype ordering and Display auto-dispatch on field access
- *(selfhost)* Port quirk impl method prototype ordering + Display auto-dispatch fixes
- *(fls)* Enum dot-shorthand completion for a compound-init field's own value
- *(selfhost)* Resolve a shadowed local by its MOST RECENT declaration, plus qualified enum-variant construction against a generic instantiation
- *(selfhost)* Infer a generic function's type param from a compound-wrapped parameter, and infer a bare generic compound literal's own type args from its field values
- *(selfhost)* Dispatch Display through a unary deref/address-of, and ensure a generic impl's Display prototype too
- *(selfhost)* Forward-declare a generic impl's async call helper before its own first (possibly sibling-triggered) call site
- *(selfhost)* Recognize a bracket literal as a valid left operand for a following ','
- *(selfhost)* Multi-dimensional raw array support (declaration, iteration) and a real array type for let-inferred literals
- *(selfhost)* Global array declarators, and emit a quirk's vtable early when a plain compound embeds it by value
- *(selfhost)* Resolve chaining off a method-own-type-param call's result
- *(selfhost)* Resolve chaining through a parenthesized alias-qualified call result
- *(selfhost)* Rename a colliding plain function's declaration and same-file call sites at import-merge time
- *(selfhost)* Rename Fun functions that shadow C bindings instead of dropping <math.h>
- *(selfhost)* Guard expression-parser recursion depth instead of overflowing the stack
- *(selfhost)* Infer a generic type param through an arithmetic argument and read alias-qualified globals
- *(selfhost)* Monomorphize a method's own type param on a plain impl
- *(selfhost)* Emit <math.h> only when the math bindings are used

### Perf

- *(fls)* Fix runaway CPU and cascading test timeouts

### Refactor

- *(stdlib)* Adopt const bindings, genericize ok() to Result<T, E>
- *(selfhost)* Use multiline raw strings for write_prelude's static C text

### Test

- Add run_examples_selfhost.sh to validate examples/ against selfhost
- *(selfhost)* Add a source-to-C test harness and first ported codegen cases
- *(selfhost)* Port codegen corpus tests (batch B)
- *(selfhost)* Port the for-loop corpus tests
- *(selfhost)* Port codegen corpus tests 124-146 (batch B)
- *(selfhost)* Port the fit exhaustiveness corpus tests
- *(selfhost)* Port the lexer corpus tests
- *(selfhost)* Port codegen corpus tests (batch A)
- *(selfhost)* Port codegen corpus tests 147-179 (batch B)
- *(selfhost)* Port codegen corpus tests (batch C)
- *(selfhost)* Port codegen corpus tests (batch A)
- *(selfhost)* Port the ast predicate and semantics corpus tests
- *(selfhost)* Port codegen corpus tests (batch C)
- *(selfhost)* Resolve imports in the test harness and port the stdlib-dependent corpus
- Point the definition expectation at len's current line in string.fn

## [0.44.0] - 2026-07-24

### Feat

- *(generics)* Impl methods can declare their own type parameter

### Fix

- *(codegen)* Silent fit-on-chr miscompile, enum-payload generic-compound type mismatch
- *(codegen)* Generic containers instantiated with a pointer type argument mangled identically to the non-pointer instantiation
- *(parser)* Concrete quirk instantiation mangling also lost pointer-arg depth
- *(parser)* Sizeof accepts a user-defined type name with a trailing pointer suffix
- *(codegen)* Self-referential recursive generic enum payloads (List<T>-style)
- *(codegen)* Plain (non-generic) functions can now fit-match a concrete generic-enum instantiation through a pointer
- *(codegen)* Close the recursive-generic-enum gap -- construction from non-generic code
- *(codegen)* Self-recursive generic function calls (bind_generic_param + call-override re-substitution)
- *(stdlib,codegen)* WaitGroup.add() grows its channel; array types now nil-comparable
- *(codegen)* Generic function calling a DIFFERENT generic function now emits the callee
- *(codegen)* Generic impl method calling a generic free function now emits the callee
- *(generics)* A method with its own type param calling a sibling method's own-type-param instantiation now mangles correctly
- *(generics)* Method chaining resolves a generic method's own-type-param return correctly
- *(generics)* Constructing a generic enum from a method's own type param no longer cross-substitutes via name collision

### Test

- *(codegen)* Confirm self-recursive constrained generic function already works

## [0.43.0] - 2026-07-22

### Chore

- *(changelog)* Update CHANGELOG for version 0.42.4 with recent fixes and dependency bumps
- Remove unused serde import from std.json and std.toml

### Fix

- *(codegen)* Torture-test fallout — Display-via-deref dispatch, exhaustive-fit false positive, enum/workspace-scan collision
- *(parser,codegen)* Uninitialized fit has_default_branch (real UB); cross-file private-function collisions

### Test

- *(fls)* Cover chained unwrap_or() on a function-parameter receiver + after incremental edits

## [0.42.4] - 2026-07-21

### Fix

- *(codegen)* Mangle generic compound type before Display auto-dispatch resolution

## [0.42.3] - 2026-07-21

### Fix

- *(fls)* Substitute concrete generic args in quirk missing-method diagnostics; fix UTF-16/byte position desync

## [0.42.2] - 2026-07-21

### Chore

- *(deps)* Bump body-parser
- *(deps)* Bump body-parser from 1.20.5 to 1.20.6 in /website/reference in the npm_and_yarn group across 1 directory (#95)

### Fix

- *(fls)* Correct completion misfires and codegen edge cases; add underscore numeric literals

## [0.42.1] - 2026-07-21

### Fix

- *(vscode)* Restore compile after vscode-languageclient v10 bump
- *(fls)* Substitute concrete generic args in fit-branch variant hover

## [0.42.0] - 2026-07-20

### Chore

- Refactor serialization quirks to use generic To<T> and From<T> mechanisms
- *(deps)* Bump the npm_and_yarn group across 2 directories with 2 updates
- *(deps)* Bump the npm_and_yarn group across 2 directories with 2 updates (#94)

### Feat

- Wire ErrorKind through stdlib errors and merge constrained-generic duplicates

## [0.41.1] - 2026-07-17

### Feat

- Implement global search modal and enhance search functionality

### Fix

- Improve handling of module and version readiness in App component

### Refactor

- Simplify result handling in channel and json implementations

### Test

- Refine expectations in std.log aliased import tests

## [0.41.0] - 2026-07-16

### Chore

- Update CHANGELOG with new features and improvements for version 0.40.0
- *(deps-dev)* Bump markdown-it
- *(deps-dev)* Bump markdown-it from 14.1.1 to 14.2.0 in /editors/vscode in the npm_and_yarn group across 1 directory (#90)
- *(deps-dev)* Bump the npm_and_yarn group across 1 directory with 2 updates
- *(deps-dev)* Bump the npm_and_yarn group across 1 directory with 2 updates (#91)
- *(deps)* Bump shell-quote
- *(deps)* Bump shell-quote from 1.8.3 to 1.8.4 in /website/reference in the npm_and_yarn group across 1 directory (#92)
- *(deps-dev)* Bump undici
- *(deps-dev)* Bump undici from 6.24.1 to 6.27.0 in /editors/vscode in the npm_and_yarn group across 1 directory (#93)

### Feat

- Add concurrency lints and align Fun Web light themes

## [0.40.0] - 2026-06-14

### Chore

- Refactor Result and Option handling in stdlib
- Refactor stdlib synchronization and threading code to use 'nil' instead of 'NULL'
- Refactor std library for improved error handling and functionality
- Refactor variable declarations to use 'let' instead of type declarations in stdlib
- Refactor channel and file handling APIs for improved error handling and consistency
- *(docs)* Enhance documentation across standard library modules
- *(deps)* Bump esbuild
- *(deps)* Bump esbuild from 0.25.12 to 0.28.1 in /website/reference in the npm_and_yarn group across 1 directory (#89)

### Feat

- Enhance documentation handling and type definitions in FLS
- Add tests for AST flushing, generic method specialization, and import aliasing
- Add data-carrying enums, private fields, and FLS support
- Add nil literal and fork keyword support for concurrency with M:N scheduler
- Add support for generic data enums with type parameters and enhance code generation
- Refactor stdlib documentation and improve iterator functionality
- Enhance generic handling and improve documentation
- Add Result handling for thread operations and enhance ThreadPool functionality
- Add WaitGroup implementation for managing completion of virtual tasks
- Enhance error handling and ergonomics for channel operations
- Add method to dynamically adjust expected task count in WaitGroup

## [0.30.2] - 2026-06-03

### Feat

- *(parser)* Implement O(1) significant-token lookahead for improved performance

## [0.30.1] - 2026-06-02

### Fix

- Unused_import on non-aliased imported function calls

### Test

- Increase warm save threshold from 150ms to 200ms

## [0.30.0] - 2026-05-28

### Chore

- *(deps-dev)* Bump fast-uri
- *(deps-dev)* Bump fast-uri from 3.1.0 to 3.1.2 in /editors/vscode in the npm_and_yarn group across 1 directory (#86)
- *(deps)* Bump the npm_and_yarn group across 2 directories with 1 update
- *(deps)* Bump the npm_and_yarn group across 2 directories with 1 update (#87)
- *(deps-dev)* Bump tmp
- *(deps-dev)* Bump tmp from 0.2.5 to 0.2.7 in /editors/vscode in the npm_and_yarn group across 1 directory (#88)

### Feat

- Add zig.testArgs configuration to settings
- Add new warning controls and refactor existing tests
- Add unused variable expect example to expected fail cases

## [0.29.1] - 2026-05-05

### Feat

- *(formatting)* Implement format-on-save cache hit for improved performance

### Fix

- *(tests)* Update format-on-save cache hit threshold to 200 ms

## [0.29.0] - 2026-05-05

### Chore

- *(deps)* Bump uuid
- *(deps)* Bump uuid from 8.3.2 to removed in /editors/vscode in the npm_and_yarn group across 1 directory (#84)
- *(deps)* Bump postcss
- *(deps)* Bump postcss from 8.5.6 to 8.5.13 in /website/reference in the npm_and_yarn group across 1 directory (#85)
- Bump Zig version to 0.16.0 in CI/release workflows

### Feat

- *(array)* Add support for multi-dimensional arrays and enhance transpilation for array types
- *(fls)* Implement diagnostic caching to improve performance and reduce compile time
- *(cli)* Add -fmt-check flag to verify formatting without modifying files
- Add run and debug commands for Fun language in VSCode extension
- *(generics)* Add constrained impl params (T: num | dec) and update vec/string stdlib

### Fix

- *(fls)* Use `fun` language id in hover code fences and improve semantic token classification
- *(editors)* Fix vim E867 syntax error, set 2-space indent across editors, update neovim docs to 0.11+ LSP API
- *(build)* Add link_libc option to all modules in build process
- *(transpiler)* Improve handling of generic instantiations and memory allocation
- Replace std.debug.print with proper IO in production code
- *(examples)* Fix asm_arch_specific expected-fail handling in run scripts
- *(fls,fmt)* Support constrained impl generics and restore field go-to-definition
- *(codegen)* Correct defer #line mapping for function-scope defers
- *(codegen)* Emit semicolon for declaration-only function prototypes

### Perf

- *(fls)* Combine format+diagnostics into single subprocess on save

### Refactor

- *(fls)* Split monolithic main.zig into modular structure

## [0.28.8] - 2026-04-13

### Feat

- Add withBasePath function to handle base URL and improve version content fetching
- Enhance Fun Web color theme with additional syntax highlighting for regex, keywords, and various types
- Add operator and punctuation highlighting across various editors and themes

## [0.28.7] - 2026-04-13

### Chore

- *(deps-dev)* Bump vite
- *(deps-dev)* Bump vite from 6.4.1 to 6.4.2 in /website/reference in the npm_and_yarn group across 1 directory (#83)

### Feat

- Add Fun Web color scheme and enhance syntax highlighting

## [0.28.6] - 2026-04-06

### Feat

- Enhance defer semantics and add comprehensive tests for defer behavior in various contexts

## [0.28.5] - 2026-04-06

### Feat

- *(tests)* Enhance e2e tests for async function completion and definition resolution

## [0.28.4] - 2026-04-06

### Chore

- Update CHANGELOG for version 0.28.3 with new features and improvements

### Feat

- Add support for variadic function signatures and corresponding tests
- Enhance documentation and return codes across synchronization and threading modules

## [0.28.3] - 2026-04-06

### Feat

- *(tests)* Add end-to-end test for let inference with async call and address argument

## [0.28.2] - 2026-04-06

### Chore

- Update CHANGELOG for version 0.28.1 and improve formatting

### Feat

- Add async thread clock ticks example and update README

## [0.28.1] - 2026-04-05

### Chore

- Update CHANGELOG for version 0.28.0 and improve formatting
- Add tests for async quirks, generic inference, and typechecking

### Feat

- *(tests)* Add end-to-end tests for let await pointer chain inference
- *(tests)* Add test for async await statement transpilation and execution
- Enhance module summary normalization and improve mobile drawer functionality
- Implement CRLF normalization in output for consistency

## [0.28.0] - 2026-04-05

### Chore

- Enhance channel functionality and testing
- Update CHANGELOG with recent enhancements, fixes, and documentation updates
- *(deps-dev)* Bump lodash
- *(deps-dev)* Bump lodash from 4.17.23 to 4.18.1 in /editors/vscode in the npm_and_yarn group across 1 directory (#82)
- Update CHANGELOG with recent enhancements, fixes, and documentation updates
- Improve code formatting and spacing across multiple files

### Docs

- Update FAQ to clarify default indexing behavior and parser settings

### Feat

- Add POSIX thread and synchronization support with pthread bindings
- Add std.channel module with single-slot blocking channels and related tests
- Enhance std.channel with bounded ring-buffer channels and add related tests
- Add timeout support for std.channel with related examples and tests
- Add select_recv_with and select_recv_timeout_with to std.channel; update documentation and examples
- Add select_recv3_rr_with and select_recv_timeout3_rr_with to std.channel; update documentation and examples
- Add clock_gettime and timespec support; update channel timeout handling
- Enhance std.channel with configurable select wait-slice tuning; update related examples and tests
- Add explicit wait-slice override for channel select functions; update examples and tests
- Add adaptive wait backoff for std.channel select; update tests and documentation
- Add configurable adaptive select wait backoff steps to std.channel; update documentation and tests
- Update std.channel to include tuning options for select wait-slice and backoff; enhance documentation and tests
- Enhance std.channel with explicit wait-slice and backoff tuning options; update examples and tests
- Add std.thread_pool module with lifecycle APIs; update examples and tests
- Add lifecycle helper functions for std.thread; update documentation and tests
- Implement mutex and condition variable lifecycle APIs; add tests for std.sync and std.thread_runtime
- Enhance std.sync_runtime and std.thread_runtime with backend selector APIs; update std.channel to use runtime synchronization primitives; add tests for new APIs
- Implement Windows backend support for runtime, sync, and thread modules; add transpile tests for new APIs
- Implement POSIX backend support for sync and thread modules; add lifecycle APIs and transpile tests
- Add runtime backend selection documentation and update stdlib README; enhance codegen tests for backend precedence
- Implement Windows backend support for synchronization and threading; enhance related documentation and tests
- Enhance Windows backend support by updating thread and sync module references; add tests for thread_windows compatibility
- Enhance std.channel with cancellation-aware select APIs and default branch handling; add tests for new functionalities
- Add cancellation-aware send/recv APIs to std.channel; enhance documentation and tests for new functionalities
- Add cancellation token support to std.channel; enhance related APIs and tests
- Enhance channel synchronization with eager initialization to prevent race conditions under multi-thread contention; add tests for channel behavior under contention and cancellation scenarios
- Implement async/await syntax support; add parsing and transpilation for async functions and await expressions; enhance tests for async behavior
- Add async/await support; enhance transpiler and parser for async function handling; improve type checking and related tests
- Add support for async function handling; implement await resolution and related prototypes; enhance error reporting for async functions
- Add async method support; enhance parser and transpiler for async function handling; implement type checking for await expressions
- Add support for async field methods and generic functions; enhance type checking for await expressions in various contexts
- Add async support for quirk methods; enhance parsing and transpilation for async method handling; implement type checking for async quirk method calls
- Enhance async quirk field dispatch tests; add cleanup for generated files and ensure proper execution
- Add support for async quirk function-returned receiver; enhance type checking and transpilation for await expressions
- Add tests for async quirk nested composite receiver handling; enhance type checking for async method calls
- Add tests for async quirk generic wrapper receiver handling in codegen and typecheck; ensure proper transpilation and type checking
- Update async quirk handling in transpiler; enhance type resolution for generic-specialized receivers and adjust test cases for Box<T> structure
- Add examples and tests for async quirk handling; include various receiver types and ensure proper transpilation and type checking
- Add async/await support to language reference and syntax highlighting; update editor configurations for async keywords
- Implement async/await completion details, hover, and signature help in e2e tests
- Implement code action handling for async diagnostics and enhance parser error handling
- Enhance diagnostic handling by adding support for diagnostic codes and updating tests for async diagnostics
- Add channel/runtime conformance matrix documentation and related tests
- Enhance CI configuration to support runtime backend matrix for testing
- Enhance CI configuration with runtime backend matrix and update documentation for channel/runtime conformance
- Add timeout to test job and simplify environment variable usage in tests
- Remove unused windows runtime backend lane and update conformance documentation
- Add tests for async function handling with let and await, including error cases
- Add async wrappers for channel send/recv and update related tests
- Add async file and network APIs, enhance examples, and update documentation
- Add async spawn and join handle example, enhance net async APIs with offload support, and update related tests
- Add tests for async task handle behavior and net offload edge return codes across backend selectors
- Enhance network compatibility for Windows in transpiler and add timeout handling in tests

### Fix

- Update clock_gettime calls to use raw pointers for ChannelAbsTime handling
- Update printf format specifiers to use %lld for long long integers

### Fls

- Harden indexing crash path and document parse mode

## [0.27.1] - 2026-04-01

### Feat

- *(docs)* Update language reference with `allow` and `expect` keywords

## [0.27.0] - 2026-04-01

### Feat

- Implement warning control mechanisms with `allow` and `expect` statements
- *(tests)* Add end-to-end tests for warning IDs completion with allow and expect keywords

## [0.26.2] - 2026-04-01

### Feat

- *(docs)* Enhance documentation comments across various modules for clarity and consistency

## [0.26.1] - 2026-04-01

### Chore

- Update CHANGELOG for upcoming release with new fixes and enhancements

### Fix

- *(release)* Ensure artifacts directory is created before building portable zip

## [0.26.0] - 2026-04-01

### Chore

- *(deps)* Bump picomatch
- *(deps)* Bump picomatch from 4.0.3 to 4.0.4 in /website/reference in the npm_and_yarn group across 1 directory (#78)
- *(deps-dev)* Bump picomatch
- *(deps-dev)* Bump picomatch from 2.3.1 to 2.3.2 in /editors/vscode in the npm_and_yarn group across 1 directory (#79)
- *(deps)* Bump the npm_and_yarn group across 1 directory with 1 update
- *(deps)* Bump the npm_and_yarn group across 1 directory with 1 update (#80)
- *(deps)* Bump path-to-regexp
- *(deps)* Bump path-to-regexp from 0.1.12 to 0.1.13 in /website/reference in the npm_and_yarn group across 1 directory (#81)

### Feat

- *(examples)* Add examples for private quirk method access and visibility rules
- *(codegen)* Enhance transpiler to support aliased imports and function resolution
- *(release)* Add portable zip support for Windows and update README
- Enhance Markdown rendering with heading permalinks and copy functionality

### Fix

- *(codegen)* Scope import alias resolution to the owning module
- *(fls)* Infer let array literal hover types in LSP
- *(fls)* Harden let inference under incomplete code and dangling operators
- *(fls)* Preserve imported enum let inference and harden incomplete-expression parsing
- *(formatting)* Adjust spacing around operators and ensure consistent formatting in examples
- *(impl)* Update implementation syntax to use 'as' for quirks
- *(cli,codegen,stdlib)* Improve Linux C build compatibility and reduce gcc warnings

## [0.25.3] - 2026-03-23

### Feat

- Enhance GitHub Pages experience by disabling runtime execution and updating related messages

## [0.25.2] - 2026-03-22

### Feat

- Add syntax highlighting for Fun language reference and integrate favicon

## [0.25.1] - 2026-03-22

### Feat

- Update CHANGELOG for version 0.25.0 with new features and dependency bumps

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

