## [0.70.2] - 2026-10-23

### 🐛 Bug Fixes

- *(codegen)* Avoid a real clang-16 wasm32-wasi frontend crash
- *(codegen)* Avoid a real clang-16 wasm32-wasi frontend crash (#215)

### ⚙️ Miscellaneous Tasks

- Bump version to 0.70.2
## [0.70.1] - 2026-10-22

### 🐛 Bug Fixes

- Keep std.process out of import_resolver.fn, broke the wasm build
- Real wasm-build regression from PR #213's find_on_path (#214)

### ⚙️ Miscellaneous Tasks

- Compile both wasm-targeted compiler frontends every run
- Bump version to 0.70.1
## [0.70.0] - 2026-10-22

### 🚀 Features

- *(process)* Add find_on_path, shelling out to command -v/where
- *(init)* Derive package/target names from the working directory
- *(playground)* Add Fizz Buzz, Enums + Fit, and Error Handling samples
- Add the no_cover warning id for per-function coverage exclusion
- *(cover)* Make -cover actually respect allow no_cover
- *(fls)* Hover and completion support for no_cover

### 🐛 Bug Fixes

- Stdlib_root's walk-up never actually reached the working directory
- *(net)* Dedupe close() declaration with std.c.process
- *(fls)* Resolve a method through an import alias by its real module
- *(test)* Use the real .exe path and backslashes for the fallback test on Windows
- *(fls)* Infer a destructured let's own element type from its initializer
- *(test)* Drop nested quotes in the Windows fallback-test command
- *(test)* Clear FUN_STDLIB_DIR without a trailing space before &&
- Stdlib resolution for fresh fun init/build after fun upgrade (#213)

### 📚 Documentation

- *(memcheck)* Fill doc-comment gaps and add blank lines between fns
- Document the no_cover warning id

### 🚜 Refactor

- Split the installed-fun stdlib fallback into its own function

### 🧪 Testing

- Cover stdlib_root's walk-up fix and find_on_path/current_dir
- Drop the stdlib fallback subprocess test, verified by hand instead

### ⚙️ Miscellaneous Tasks

- *(docs)* Update CHANGELOG.md
- Bump version to 0.70.0

### 💼 Other

- Temporary stderr trace for the Windows stdlib fallback bug
## [0.69.0] - 2026-10-21

### 🚀 Features

- Memcheck now also catches buffer underflow, via a leading guard page
- Add member_declaration_from_tokens, shared degraded-parse member lookup
- Fun test's own outer worker pool defaults lower under -memcheck
- A compiled test binary's own inner worker pool defaults lower under -memcheck
- Operator overloading covers index assignment and chained operands
- *(manifest)* Description, license, authors, repository, min_fun_version
- *(cli)* Add fun upgrade, and enforce min_fun_version on fun build
- More [package] manifest fields, min_fun_version gate, fun upgrade command (#211)
- *(reference)* Add a View source link alongside each symbol's Copy link

### 🐛 Bug Fixes

- Fls shows the real import-resolution error, not a generic placeholder
- Dot-completion no longer dumps unrelated names when the receiver's type can't be resolved
- Completion no longer triggers on '.'/',' typed inside a string literal
- Memcheck now catches a one-element buffer overflow, not just a whole-page one
- A line-count-changing fast-reparse edit no longer leaves later declarations stale
- A dot-shorthand enum default value now shows in hover/signature help
- A call-inferred local now resolves even when an unrelated import is broken
- Hover on a call-inferred local now resolves when an unrelated import is broken
- Go-to-definition on a call-inferred local's member now resolves through a broken import
- Memcheck's crash handler now survives a real stack overflow
- Add the missing Windows stub for __fun_mc_ensure_altstack
- -memcheck's own inner worker default scales with real core count, not a flat 2
- Memcheck's allocation lookup was O(n) under one lock, O(n^2) total
- Map<str,_>.to_string() under-budgets its buffer by one byte
- Fls completion/diagnostic bugs, memcheck overflow precision (#207)
- Memcheck's guard pages grew forever, exhausting real memory
- Memcheck's own reports warned under -Wformat on Linux
- Wasm CI smoke test warnings, and bump the deprecated setup-emsdk action
- Pin emsdk to a known-working version, not latest
- Drop the emcc flag that bumped the wasm output's own Node requirement
- Memcheck's real memory ceiling; operator overloading improvements (#208)
- *(fls)* Free leaked source text in import-resolution helpers
- *(codegen)* Always take ownership of a variadic 's'-tagged argument
- *(memcheck)* Pool small allocations into shared guarded slabs
- Memcheck's guard-page overhead and three real leaks; add Codecov (#210)
- *(upgrade)* Mark the real-subprocess tests sequential
- *(upgrade)* Windows cmd quoting, plus real local-fixture coverage
- *(upgrade)* Give cmd.exe's own builtins backslash paths
- *(fs)* Exists() must check is_dir first, not just fopen
- *(upgrade)* Refuse to touch a Program Files (MSI) install
- *(reference)* Make the std explorer's doc-comment extraction strict
- *(reference)* Module-top comment also absorbed the first symbol's own doc
- *(reference)* Real WebKit scroll-paint bug behind the symbol tabs

### 📚 Documentation

- Document -memcheck's own lower default test parallelism
- Update the stale comment and env-var table for the revised inner default
- Update operator overloading for op_index_set and the new operand shapes
- Document the new [package] fields and fun upgrade
- *(stdlib)* Fill every remaining doc-comment gap in std explorer
- Fill every stdlib doc-comment gap, fix std explorer's mixed text (#212)

### 🚜 Refactor

- Move call-inferred-local resolution into symbols.fn, shared with hover

### 🎨 Styling

- Drop caps-emphasis words from this session's own comments

### 🧪 Testing

- Regression coverage for the import-diagnostic, dot-completion, and string-trigger fixes
- Regression coverage for overflow precision and free-then-arithmetic-only
- Cross-file generic/fast-reparse regression coverage from this session's torture pass
- Regression coverage for a genuine A<->B import cycle, already handled correctly
- Regression coverage for buffer underflow detection
- Regression coverage for the dot-shorthand default value fix
- Regression coverage for call-inferred locals through a broken sibling import
- Regression coverage for hover on a call-inferred local through a broken import
- Regression coverage for memcheck's quarantine recycling
- Regression coverage for operator overloading's new dispatch

### ⚙️ Miscellaneous Tasks

- *(docs)* Update CHANGELOG.md
- Restore the memcheck step's own original parallelism explicitly
- Keep -memcheck's lower default parallelism in CI too
- Upload coverage to Codecov
- Move the coverage min/exclude into fun.toml's own [coverage]
- Fill in fun.toml's new [package] fields for real
- Bump version to 0.69.0

### 💼 Other

- *(upgrade)* Print the real cmd.exe result on a failed test move
- *(upgrade)* Diagnose the remaining _rm_rf setup failure on Windows
## [0.68.0] - 2026-10-15

### 🚀 Features

- Wire fls inlay hints into the playground editor
- Track a document's last ranged edit, for incremental fls reparse
- Parse_program_cached can hand back its own global_symbols
- Incremental single-declaration reparse for fls, on by default
- Cache the playground's wasm modules in the browser across deployments
- Wire up fun.fls.debugImports, which the extension already sent
- Add ternary conditional expressions (cond ? a : b)
- Add a built-in memory checker (-memcheck)
- Wire -memcheck into fun test, leak reporting off by default

### 🐛 Bug Fixes

- >>/<< split tokens got a bare string literal, crashing when freed
- Expression-rotation and tuple-access rewrites orphan their old node
- Canonical_type_name always allocated, though every caller borrows it
- Entry file's own re-parse leaked its token strings every edit
- Number and boolean literals leaked their intermediate text
- Mangled_name allocated on generics, though every caller borrows it
- Take_sizeof_pointer_stars leaked at both its call sites
- Completion offered private names from other files
- Entry file's cached parse aliased the live editor buffer
- Every scope entity's own declaration node leaked
- Cross-file reference to an untyped const emitted invalid C
- A let local's hover leaked a referenced const's own type text
- Inlay hint background used a fixed color, not a themed one
- Destructuring let leaked its own whole-statement node
- A CheckedType's own generic/tuple args were never freed
- Every function body and top-level function leaked its own node
- A TypeEnv binding could leak or double-free another's type
- _unmangled_method_name leaked its own prefix on every call
- Expression rotation discarded a wrapper's own binding
- Preload claim leaked the normalized path on every re-visit
- Register_impl's own fresh method table leaked when reused
- _erase_type_params leaked the type it discarded
- _erase_named leaked the type it discarded
- _fun_format_specs leaked every parsed placeholder word
- Three more CheckedType ownership leaks in Checker
- Local_types' own pointer-suffixed entries leaked on every clear
- A method table's own leaf-name keys leaked every typecheck pass
- A comma-expression assert leaked its own comma wrapper's binding
- Check_variable's own declared type leaked on every path
- Stdlib/deps path helpers crashed or leaked on every return path
- Two deps_project_root callers never freed its now-owned result
- Two more normalized-path leaks in the import merge walk
- A malformed impl method leaked its own node and parser state
- A compound field line leaked its own shared declared type
- _erase_signature leaked a generic method's own original args
- A compound's own field types leaked on every typecheck pass
- An impl method's own generated name leaked on every teardown
- Operator-token backoff and two angle-split leaks
- _import_is_read leaked every dotted-path segment it split
- Parse_document leaked every line of the TOML text it read
- Fit-subject type resolution leaked its own borrowed/owned strings
- TomlDoc/TomlTable never freed their own keys or values
- Get_str/table_field handed back a pointer the caller's own doc.free() just freed
- Fit over a plain function call skipped exhaustiveness checking
- A stored MethodTable/Set/Vec could be freed out from under its own map entry
- The workspace symbol table held borrowed strings across edits
- A fast-reparsed declaration's own strings were freed while still borrowed
- Every reported Diagnostic.message leaked, every edit
- A dotted or '..' import path leaked its own built string
- Every outgoing LSP message leaked its own quoted method name
- A preload error's own message leaked at every discard site
- Cached C-compiler resolution ignored a later FUN_CC change
- The playground's idle warm-up eagerly loaded the ~105MB clang package
- An example with no pre-baked wasm module dead-ended with no backend
- Checker.methods copied a growing inner map on every re-registration
- Freeing a method table's own key mid-teardown crashed a later lookup
- Editing one open document corrupted hover/goto-def in another
- Serialize preload during the bulk workspace scan
- Detach fire-and-forget scheduler/watchdog threads
- Track the version a ranged edit's own range came from
- Node_clone shared an owned import path with its original
- Fit over a method call never checked exhaustiveness
- A hoisted temp's own #line directive could read uninitialized data under -g
- Std.memcheck depending on std.io created a circular forward reference
- Fls debug-import logging passed a 64-bit length where printf expects int
- Memcheck's own hand-written C used long long where num maps to int64_t
- Memcheck's own Windows block included windows.h without the lean guard

### 📚 Documentation

- Note why >> splitting can't free its own replaced token
- Document the memory checker and ternary conditional expressions

### ⚡ Performance

- Cache resolve_c_compiler() across one process's compiles
- Diagnose() reparsed the whole file a second time on every edit
- Goto-definition always paid for a full workspace symbol rebuild

### ⚙️ Miscellaneous Tasks

- Check for memory issues under -memcheck, manual trigger only
- Bump version to 0.68.0

### 💼 Other

- Incremental reparse, hardening, and a zero-leak pass (#203)
- Fix a real crash and a goto-definition correctness/perf bug (#204)
## [0.67.0] - 2026-10-07

### 🚀 Features

- Render fls hover/completion docs as real markdown, not raw text
- Full screen toggle, named file creation, and a discoverability hint
- Operator overloading via impl methods (op_add, op_eq, ...)

### 🐛 Bug Fixes

- Switching Playground files silently discarded unsaved edits
- Safari clipped the hover tooltip; light-theme tree-button colors
- Op_index's own return type, not its receiver's, under MSVC codegen

### 📚 Documentation

- Fix dead Wasmer JS SDK docs link
- Document fixed-size stack-allocated arrays (num[N])
- Document operator overloading

### 🧪 Testing

- Operator overloading
- Print actual output on the MSVC-strict operator-overload mismatch
- Match this file's own contains() convention for the MSVC-strict check

### ⚙️ Miscellaneous Tasks

- Bump version to 0.67.0

### 💼 Other

- Real markdown rendering, Safari tooltip fix, full screen, named files (#200)
## [0.66.2] - 2026-10-06

### 🐛 Bug Fixes

- Wasm playground hangs on any blocking wait, not just pthread_join
- Detect await-only concurrency, not just explicit fork
- Prebake-wasm.mjs missed fenced examples indented inside list items
- Doc examples that could never actually run once prebake actually tried
- Wasm Playground hangs on any blocking concurrency (#199)

### ⚙️ Miscellaneous Tasks

- Bump version to 0.66.2
## [0.66.1] - 2026-10-06

### 🐛 Bug Fixes

- A repeated -D flag silently dropped every value but the last
- Reject fork in the Playground's run path instead of hanging the tab
- Doc examples that could never actually run in the Playground
- Playground editor not respecting the site's theme

### ⚡ Performance

- Serialize fls sessions, gate live features until warm

### ⚙️ Miscellaneous Tasks

- Bump version to 0.66.1
## [0.66.0] - 2026-10-06

### 🚀 Features

- *(website)* Consolidate the Playground into one multi-file CodeMirror block
- *(fls)* A reload-per-call wasm entry point for in-browser diagnostics
- *(website)* Wire real fls diagnostics into the Playground editor
- *(fls)* Generalize the wasm entry point to replay any LSP messages
- *(website)* Color the Playground editor with the real Fun Web theme
- *(website)* Wire hover, completion, goto-definition, and signature help

### 🐛 Bug Fixes

- Async main's shadow-renamed entry point got a conflicting prototype
- Runnable code block cursor desync and ugly title bars
- Surface the real C compiler error instead of a generic message

### ⚡ Performance

- Load the Playground's wasm modules eagerly, cache-busted per build

### ⚙️ Miscellaneous Tasks

- Bump version to 0.66.0
## [0.65.1] - 2026-10-01

### 🐛 Bug Fixes

- Make the deployed Playground actually work

### ⚙️ Miscellaneous Tasks

- Bump version to 0.65.1
## [0.65.0] - 2026-10-01

### 🚀 Features

- *(codegen)* Reachability-based dead code elimination
- *(driver)* Wire prune_unreachable, off for library builds
- *(codegen)* Reachability-based dead code elimination (Tier 2 PR 1) (#192)
- *(driver)* Extract the lowering pipeline into lower.fn
- A minimal wasm-buildable compile-Fun-to-C entry point
- Minimal wasm-buildable compile-Fun-to-C entry point (Tier 2 PR 2) (#193)
- *(website)* A client-side Fun-to-wasm compile pipeline
- *(website)* Wire client-side compile into the Run button
- Wire a real client-side C-to-wasm compiler into the Playground (Tier 2 PR 3) (#194)

### 🐛 Bug Fixes

- *(ci)* Gate the website build on release assets being uploaded
- *(ci)* Gate the website build on release assets being uploaded (#191)
- *(codegen)* Never prune under coverage, it needs every body present
- *(codegen)* Mark an import-alias collision's renamed target too
- *(driver)* Drop two now-unused codegen imports
- *(import_resolver)* Sequential fallback for parallel preload

### 📚 Documentation

- Document the in-browser Playground's two-stage pipeline

### 🚜 Refactor

- *(warnings)* Make the read-collection helpers reusable
- *(codegen)* Inject host_arch instead of resolving it internally
- *(driver)* Compile_to_c_cover delegates to lower_to_c

### 🧪 Testing

- *(codegen)* Cover reachability pruning

### ⚙️ Miscellaneous Tasks

- Bump version to 0.65.0

### 💼 Other

- *(website)* Compile the compiler frontend to wasm at build time
## [0.64.0] - 2026-09-30

### 🚀 Features

- *(driver)* Emscripten as a new C-compiler backend, real wasm target
- Emscripten as a new C-compiler backend (wasm target, Tier 1 PR 1) (#184)
- *(codegen)* Reject std.net/std.process for the wasm target
- *(driver)* Wire emscripten_mode; test the wasm rejection messages
- Reject std.net/std.process for the wasm target (Tier 1 PR 2) (#185)
- *(website)* Pre-bake docs examples to wasm at build time
- Pre-bake docs examples to wasm at build time (Tier 1 PR 4) (#189)
- *(website)* Prebake playground samples too, normalize hash input
- *(website)* Run pre-baked wasm examples client-side, no backend
- Run pre-baked wasm examples client-side, no backend (Tier 1 PR 5) (#190)

### 🐛 Bug Fixes

- *(website)* Stop hiding the Playground tab on GitHub Pages
- *(wasm)* Skip main()'s pthread wrapper on the emscripten target
- *(website)* Name the prebaked entry file by hash before compiling
- *(website)* Run each prebaked wasm module in its own iframe

### 🚜 Refactor

- *(website)* Extract playground samples into a shared module

### ⚙️ Miscellaneous Tasks

- Real emscripten toolchain on the Linux lane, smoke-tested
- Real emscripten toolchain on the Linux lane (Tier 1 PR 3) (#186)
- Build fun + emscripten in the website release job for prebaking
- Bump version to 0.64.0
## [0.63.0] - 2026-09-30

### 🚀 Features

- *(time)* Use reentrant gmtime/localtime/ctime
- *(typecheck)* Recognize shape-downcast fit arms
- *(codegen)* Dispatch shape-downcast fit arms via vtable identity
- *(parser)* Parse bare Type(binding) as a shape-downcast fit pattern
- *(warnings)* Exhaustiveness for shape-downcast fit blocks
- *(fls)* Hover on a shape-downcast fit arm's binding
- *(fls)* Fill-in-missing-arms code action for shape-downcast fit
- *(parser)* Parse Type<Args>(binding) for a concrete generic instantiation
- *(typecheck)* Accept a concrete generic shape-downcast implementor
- *(warnings)* Exhaustiveness covers a concrete generic implementor too

### 🐛 Bug Fixes

- *(typecheck)* Match shape-downcast arms to the real parsed AST shape
- *(codegen)* Match shape-downcast emission to the real parsed AST shape
- *(typecheck)* Clear error for a wrong-arity shape-downcast arm
- *(typecheck)* Reject a generic implementor in shape-downcast fit
- *(warnings)* Exclude generic implementors from fit exhaustiveness
- *(codegen)* Trigger early instantiation for a generic downcast target
- Support multiple concrete instantiations of the same generic shape
- *(codegen)* Fix fit's shape gate and two more ambiguous template matches
- *(typecheck)* Auto-resolve bare generic shape-fit target when unambiguous
- *(codegen)* Mirror the bare generic shape-fit auto-resolve
- *(warnings)* Credit auto-resolved bare shape-fit arms as covered
- *(codegen)* Pin shape-fit binding's own #line, don't inherit
- *(fls)* Mirror bare generic shape-fit auto-resolve for hover
- *(fls)* Mirror bare generic shape-fit auto-resolve for completion
- *(fls)* Nest shape/enum distinction, don't widen the elif chain
- *(codegen)* Use strcmp for str ==/!= comparisons; split MSVC string literals
- *(codegen)* Use null-safe __fun_str_eq for str literal comparisons
- *(codegen)* Use strcmp for str ==/!= on MSVC; split long string literals (#182)
- *(website)* Recognize shape declarations in the std explorer
- *(website)* Express 5 rejects a bare wildcard route, crashed prod server
- *(website)* Type heading renderer children as ReactNode, not unknown
- *(installer)* Don't overwrite a running binary in place; drop hardcoded FUN_CC=gcc
- Shapes missing from std explorer, Express 5 crash, installer overwrite/FUN_CC gaps (#183)

### 📚 Documentation

- *(examples)* Add shape-downcast fit example
- Document fit over a shape (structural downcasting)
- Note the generic-implementor limitation for shape-downcast fit
- Update the generic-implementor note for shape-downcast fit
- Bare generic auto-resolve for shape-fit downcast

### 🎨 Styling

- Fix indentation in use_str_eq condition after fmt

### 🧪 Testing

- Shape-downcast fit dispatch and ordinary-fit regression coverage
- Shape-downcast fit typecheck errors, exhaustiveness, and hover
- Shape-downcast fit code action coverage
- Shape-downcast fit rejects generic implementors
- Concrete generic shape-downcast dispatch, exhaustiveness, field access
- Two instantiations of the same generic implementing one shape
- Bare generic shape-fit auto-resolve, unambiguous and ambiguous
- Fls hover/completion on auto-resolved shape-fit binding

### ⚙️ Miscellaneous Tasks

- *(examples)* Rename quirks.fn to shapes.fn
- Bump version to 0.63.0

### 💼 Other

- Use reentrant gmtime/localtime/ctime (#180)
## [0.62.1] - 2026-09-29

### 🚀 Features

- *(editors)* Update grammars for the shape rename (#177)
- *(codegen)* Emit reentrant gmtime/localtime/ctime prelude helpers

### ⚙️ Miscellaneous Tasks

- *(zed)* Bump the extension version to 0.1.1 (#178)
- Bump version to 0.62.1
## [0.62.0] - 2026-09-29

### 🚀 Features

- Remove the 'quirk' keyword, 'shape' is the only spelling now (#176)

### ⚙️ Miscellaneous Tasks

- Bump version to 0.62.0
## [0.61.1] - 2026-09-29

### 🚀 Features

- *(stdlib)* Rename std.quirks to std.shapes, migrate declarations and prose to shape
- Migrate the compiler's own source, docs, and internals from quirk to shape (Phase B) (#175)

### 📚 Documentation

- *(examples)* Migrate quirk declarations and prose to shape
- Teach shape as the primary keyword, note quirk still works

### 🚜 Refactor

- Rename the Quirk AST node kind and parser internals to Shape
- *(codegen)* Rename quirk-dispatch internals to shape
- *(semantics)* Rename quirk-tracking internals to shape
- *(fls)* Rename quirk-related internals and labels to shape

### 🧪 Testing

- Follow the internal quirk->shape identifier rename

### ⚙️ Miscellaneous Tasks

- Bump version to 0.61.1
## [0.61.0] - 2026-09-29

### 🚀 Features

- *(lexer)* Add 'shape' as a lexer keyword, and its own AST spelling flag
- *(parser)* Accept 'shape' as a full synonym for 'quirk'
- *(fmt)* Recognize 'shape' as a block keyword
- *(fls)* Complete, hover, and render 'shape' the same as 'quirk'

### 🐛 Bug Fixes

- *(examples)* Rename a parameter that now collides with the 'shape' keyword

### 🧪 Testing

- Cover 'shape' as a synonym for 'quirk' across parser, fmt, and fls

### ⚙️ Miscellaneous Tasks

- Bump version to 0.61.0
## [0.60.2] - 2026-09-29

### 🚀 Features

- *(zed)* Add extension manifest and language config
- *(zed)* Add language queries
- *(zed)* Add fls language server integration
- *(zed)* Add Fun Web theme extension manifest
- *(zed)* Add Fun Web dark and light themes
- *(zed)* Ship run tasks and fuzz runnables
- *(zed)* Add a debug build task and document debugging
- Add Zed extension and Fun Web themes (#170)

### 🐛 Bug Fixes

- *(zed)* Quote task arguments so test names with spaces work
- *(zed)* Align highlights with the VS Code grammar
- *(zed)* Let specific highlight captures override the identifier fallback
- *(zed)* Color method calls above the field fallback
- *(zed)* Set diagnostic, git-status and scrollbar colors for the Fun Web theme
- *(zed)* Set diagnostic, git-status and scrollbar colors for the Fun Web theme (#172)
- *(warnings)* Walk test and fuzz block bodies for warning checks
- *(warnings)* Keep walk_function's own doc comment attached to it
- *(fls)* Show const and its literal value when hovering a local const
- Silence assert_constant on deliberately-constant asserts inside test blocks
- *(warnings)* Walk test and fuzz block bodies for warning checks (#173)

### 📚 Documentation

- *(zed)* Add extension readme
- Mention the Zed extension
- *(zed)* Describe the bundled tasks
- *(zed)* Note that the downloaded release is not added to PATH
- *(zed)* Note which theme colors are Zed-specific

### 🧪 Testing

- *(warnings)* Torture every warning category inside test and fuzz blocks

### ⚙️ Miscellaneous Tasks

- *(zed)* Use the omdxp handle as author
- *(zed)* Rename the extension id to fun-lang
- *(zed)* Rename the extension id to fun-lang (#171)
- Bump version to 0.60.2
## [0.60.1] - 2026-09-25

### 🐛 Bug Fixes

- *(fls)* Resolve a fit subject's method call through a field receiver
- *(fls)* Resolve fit subjects that call a method through a field (#169)

### 🧪 Testing

- *(fls)* Cover hover in a fit over a method call on a field
- *(fls)* Match the stdlib link target in any install layout

### ⚙️ Miscellaneous Tasks

- Bump version to 0.60.1
## [0.60.0] - 2026-09-24

### 🚀 Features

- Sequential keyword hover, editor support, and isolated env-var tests
- Sequential keyword hover, editor support, and isolated env-var tests (#165)
- Coverage report model with lcov, Cobertura, JSON, HTML and text output
- Instrument statements for code coverage
- Fun test -cover, with report formats, a minimum and exclusions
- Read the coverage minimum and exclusions from fun.toml
- Test Explorer and coverage in the VS Code extension
- Code coverage for fun test, reports, an 80% CI gate, and VS Code test explorer (#168)

### 🐛 Bug Fixes

- Give Windows children only their stdio handles, not every inheritable handle
- Infer a generic type parameter from a negated argument
- Keep the full precision of decimal literals
- Keep a call-result receiver's temp inside a generic method's own body
- Evaluate a call-result receiver where its expression runs, not before it
- Print `true` and `false` for a {flag} placeholder given a literal or comparison
- Reject == and != on an enum whose variants carry data
- Give a fork inside a test the fork runtime when tests are compiled
- Keep the generated C free of two avoidable compiler warnings
- Include <intrin.h> for the coverage counter under MSVC
- List the extension test files explicitly
- Treat a negative start or length in substr as zero

### 📚 Documentation

- State exactly whose tests run and which files coverage measures
- Describe the [coverage] manifest table, enum equality, and decimal literal precision

### ⚡ Performance

- Build with the C optimizer in `fun build`, add per-phase test timing
- Build with the C optimizer in fun build, add per-phase test timing (#166)
- Splice the codegen output buffer in place instead of rebuilding it
- Run only a file's own tests, search the output in place, cache typedef lookups
- Splice the codegen output buffer in place instead of rebuilding it (#167)

### 🧪 Testing

- Report the C compiler's stdout and exit code when a test program is rejected
- Cover std.json, and fix three parser gaps it exposed
- Cover std.log (text and JSON output, levels, fields, sinks)
- Cover std.time (UTC and local formatting, arithmetic, try_ forms, sleeping, human strings)
- Cover std.math and std.array
- Cover std.set and std.thread_pool
- Cover std.vec (growth, checked reads, insert/remove, resize, slicing, sorting, searching, join, display)
- Cover std.map (lookup, replace, removal, growth, iteration, clone, display)
- Cover std.io (format, fmt_ helpers, files, sinks, rotating sink)
- Cover std.fs (files, the Fs value, failures, lines, directories)
- Make the std.fs directory test repeatable by cleaning up what it creates
- Cover ast_print, and import the warnings module it already used
- Cover std.channel (buffering, codes, timeouts, cancellation, results, growth, select, and producer/consumer tasks over the async wrappers)
- Run the suite, single-file and lint machinery against small projects, and cover the fuzz and compiler-selection helpers
- Cover dependency resolution against local git repositories (tag, branch, revision, default, transitive, lock reuse, conflicts)
- Pin which paths coverage treats as project code (not stdlib, dependencies, fixtures or build output)
- Run the nested-suite driver tests one at a time

### ⚙️ Miscellaneous Tasks

- Run the Linux suite with coverage, enforce 80%, and publish the reports
- Pin the Linux runners to ubuntu-24.04
- Bump version to 0.60.0
## [0.59.0] - 2026-09-24

### 🚀 Features

- *(stdlib)* Add Atomic<T>, a lock-free atomic primitive
- *(stdlib)* Add Atomic<T>, a lock-free atomic primitive (#153)
- *(stdlib)* Add Guarded<T>, a Mutex-backed value for arbitrary T
- *(stdlib)* Add Guarded<T>, a Mutex-backed value for arbitrary T (#154)
- *(fls)* Go to definition on a bare generic type-parameter name
- *(fls)* Go to definition on a bare generic type-parameter name (#158)
- *(codegen)* Platform-specific SO_RCVTIMEO/SO_SNDTIMEO prelude shim
- Comma-separated OR patterns in a fit arm (.A, .B -> { ... })
- .tag_value() builtin enum method, real language support
- Std.http, a full HTTP client and server-side router
- Std.http (client + server router) plus the compiler fixes it needed (#159)
- Real client TLS (OpenSSL on POSIX, SChannel on Windows)
- Std.crypto - hashing, HMAC, AEAD, Ed25519, ports and adapters
- *(http)* Async/Channel-driven client and server variants
- Real TLS (OpenSSL POSIX + SChannel Windows), then crypto + async http (#160)
- Parallel test runner, both across files and within one file
- Sequential test keyword + slow-test reporting (bootstrap-safe) (#163)

### 🐛 Bug Fixes

- *(net)* Make std.net actually work on Windows, add connect/tcp_connect
- *(fmt,cli)* Stop baking trailing whitespace into blank comment lines; reject multi-file input where only one is checked
- *(net)* Move round-trip test breadcrumbs to unbuffered stderr
- *(codegen)* Try closesocket before _close in the Windows close() patch
- *(net)* Make std.net actually work on Windows, add connect/tcp_connect (#152)
- *(codegen)* Use int64_t, not long long, in the atomic prelude shims
- *(codegen)* Use int64_t, not long long, in the atomic prelude shims (#155)
- *(codegen,driver)* Suppress cl.exe filename echo and fix C4047 on str[] defer return
- *(codegen,driver)* Suppress cl.exe filename echo and fix C4047 on str[] defer return (#156)
- *(fls)* Hover on a bare generic type-parameter name
- Run the formatter, and fix a wrong test column
- *(fls)* Hover on a bare generic type-parameter name (#157)
- *(codegen)* Tagged-union enum honors an explicit variant discriminant
- *(codegen)* A bare function type used as a generic argument mangles
- *(net)* Tcp_listen sets SO_REUSEADDR, fixing a real CI flake
- *(net)* Tcp_connect resolves real hostnames, not just numeric IPs
- Keep 'sequential test' out of the compiler's own bootstrap graph
- MSVC environment probe races under the new parallel test runner
- Never reuse a worker's own compile-path tag across files
- Revert too-broad prototype fix, relocate process_id, fix two tests
- Retry the C compile step on transient empty-output failures
- Lower default test parallelism on Windows
- Retry the outer per-file compile step too, not just the inner one
- *(ci)* Set up the MSVC arm64 environment for the aarch64-windows-gnu release build
- Close Windows process spawn/wait races behind flaky test exit codes
- Stop freeing map keys before the map has finished looking them up
- Close Windows process spawn/wait races behind flaky test exit codes (#164)

### 📚 Documentation

- Remove stray other-language mentions from comments and docs
- Remove stray other-language mentions (#161)

### 🧪 Testing

- *(net)* Remove the round-trip test's diagnostic breadcrumbs

### ⚙️ Miscellaneous Tasks

- *(vscode)* Bundle the extension with esbuild
- *(vscode)* Bundle the extension with esbuild (#151)
- Bump version to 0.59.0
## [0.58.2] - 2026-09-22

### 🐛 Bug Fixes

- *(typecheck)* Check enum variant constructor arguments against their payload
- *(typecheck)* Check enum variant constructor arguments against their payload (#148)
- Report every name the generated C cannot accept (#149)
- *(codegen)* Run every compiled program's main() on a worker thread with a large stack
- *(codegen)* Run every compiled program's main() on a worker thread with a large stack (#150)

### 📚 Documentation

- Explain the 128 MB main() stack and how it differs from fork/await's 8 MB
- Fix two broken internal links in language.md

### ⚙️ Miscellaneous Tasks

- Move release.yml's actions to Node 24 releases
- Move release.yml's actions to Node 24 releases (#147)
- Bump version to 0.58.2
## [0.58.1] - 2026-09-19

### 🚀 Features

- *(stdlib)* Default Result's error type to Error
- *(stdlib)* Default Result's error type to Error (#144)

### 🐛 Bug Fixes

- *(codegen)* A for loop over a plain iterator type iterates a copy
- *(codegen)* A for loop over a plain iterator type iterates a copy (#145)

### ⚙️ Miscellaneous Tasks

- Use the maintained msvc-dev-cmd fork
- Use the maintained msvc-dev-cmd fork (#146)
- Bump version to 0.58.1
## [0.58.0] - 2026-09-19

### 🚀 Features

- *(stdlib)* Name sort_by's comparison function type Comparator<T>
- *(stdlib)* Name sort_by's comparison function type Comparator<T>; ci: checkout v7 (#142)
- *(lang)* Add default generic type parameters
- *(lang)* Add default generic type parameters (#143)

### 🐛 Bug Fixes

- For over a pointer to a collection, fls default handling, impl default error

### ⚙️ Miscellaneous Tasks

- Move actions/checkout to v7 in ci-dev
- Bump version to 0.58.0
## [0.57.3] - 2026-09-19

### 🚀 Features

- *(cli)* Add fun lint, a tree-wide warning report
- *(cli)* Add fun lint, a tree-wide warning report (#140)

### ⚙️ Miscellaneous Tasks

- Lint the compiler and stdlib with fun lint
- Lint the compiler and stdlib with fun lint (#141)
- Bump version to 0.57.3
## [0.57.2] - 2026-09-19

### 🐛 Bug Fixes

- *(typecheck)* Reject a bare .Variant that its expected enum does not declare
- *(typecheck)* Also reject an unknown .Variant nested in another variant's payload
- *(typecheck)* Reject a bare .Variant that its expected enum does not declare (#138)
- *(parser)* Bind a postfix propagation inside a prefix operator's operand
- *(parser)* Bind a postfix propagation inside a prefix operator's operand (#139)

### 🚜 Refactor

- *(codegen)* Use the bare .UnsupportedNode shorthand in ?! calls
- *(codegen)* Use the bare .UnsupportedNode shorthand in ?! calls (#137)

### ⚙️ Miscellaneous Tasks

- Bump version to 0.57.2
## [0.57.1] - 2026-09-19

### 🚀 Features

- *(fls)* Complete fls coverage for ?!(.Variant), document the syntax

### 🐛 Bug Fixes

- *(lang)* Accept a bare .Variant shorthand as ?!'s error argument
- *(lang)* Accept a bare .Variant shorthand as ?!'s error argument (#136)

### 🚜 Refactor

- *(codegen)* Use ?! for guard-then-unwrap sites in codegen.fn
- *(codegen)* Use ?! for guard-then-unwrap sites in codegen.fn (#135)

### ⚙️ Miscellaneous Tasks

- Bump version to 0.57.1
## [0.57.0] - 2026-09-18

### 🚀 Features

- *(codegen)* Inline a user Iterator's own next() body into for loops
- *(lang)* [**breaking**] Fold range-for into the general Iterator<T> mechanism
- *(lang)* Typecheck resolves a for loop's real element type generally
- *(lang)* [**breaking**] Vec<T> implements Iterator<T> directly (step 4/7)
- *(lang)* [**breaking**] Map<T> and Set<T> implement Iterator<T> directly (step 5/7)
- *(alias)* Rebuild variadic generic alias params on real tuple types
- *(alias)* Rebuild variadic generic alias params on real tuple types (#131)
- *(stdlib)* Add std.prelude; fix(warnings): allow/expect singular vs plural scope
- *(stdlib)* Add std.prelude; fix(warnings): allow/expect singular vs plural scope (#132)
- *(stdlib)* Add Steppable<T>/StepRange<T> for range iteration over any ordered type
- *(stdlib)* Add Steppable<T>/StepRange<T> for range iteration over any ordered type (#133)
- *(lang)* Add ?!(err)/!? cross-type propagation sugar
- *(lang)* Add ?!(err)/!? cross-type propagation sugar (#134)

### 🐛 Bug Fixes

- *(cli)* Reserve a larger MSVC stack for every compiled program, not just tests
- *(ci)* Patch each Windows bootstrap stage's PE stack reserve directly
- *(codegen)* Build the base-name prefix via StringBuilder, not inline format()
- *(codegen)* Fix and unify the plain-type Iterator call-based fallback
- *(codegen)* Substitute tuple-typed generic arguments in resolve_type_subst
- *(codegen)* Substitute tuple-typed generic arguments in resolve_type_subst (#129)
- *(codegen)* Carry a tuple-typed enum payload's real DataType through instantiation
- *(codegen)* Carry a tuple-typed enum payload's real DataType through instantiation (#130)
- *(fls)* Recognize ?!(err)/!? wherever ?/! already had dedicated support

### 📚 Documentation

- Document the completed Iterator<T> for-loop dispatch mechanism

### ⚙️ Miscellaneous Tasks

- Bump version to 0.57.0
## [0.56.0] - 2026-09-17

### 🚀 Features

- *(lang)* Reject a pointer-typed type-alias body
- *(lang)* Add unused_type_alias warning, document quirk-bodied aliases

### 🐛 Bug Fixes

- *(lang)* Real memory-corruption bug in bound-list type-alias constraints
- *(fls)* Hover on a bare enum-variant shorthand nested inside another shorthand's call

### 🧪 Testing

- *(fls)* Lock in a type alias's own workspace/document symbol coverage

### ⚙️ Miscellaneous Tasks

- Bump version to 0.56.0
## [0.55.0] - 2026-09-16

### 🚀 Features

- *(lang)* Make 'use'/'flag' the canonical spelling of 'imp'/'bin'
- *(lang)* Let a generic bound name a quirk or a full type expression
- *(lang)* Add type aliases (als Name<T> = <type>;)

### 🐛 Bug Fixes

- Leak fixes in alias expansion, bump Windows test stack to 128MB

### ⚙️ Miscellaneous Tasks

- Bump version to 0.55.0
## [0.54.0] - 2026-09-15

### 🚀 Features

- *(lang)* Accept 'use'/'flag' as alternate spellings of 'imp'/'bin'

### 🐛 Bug Fixes

- *(deps)* Reject a dependency name that collides with a keyword

### ⚙️ Miscellaneous Tasks

- *(docs)* Update CHANGELOG.md
- Bump version to 0.54.0
## [0.53.6] - 2026-09-12

### 🐛 Bug Fixes

- *(fls)* PACKAGE_NAME/PACKAGE_VERSION reflect live fun.toml, real goto

### ⚙️ Miscellaneous Tasks

- Bump version to 0.53.6
## [0.53.5] - 2026-09-12

### 🐛 Bug Fixes

- *(driver)* Add bat-wrapper fallback for cl.exe when INCLUDE not set

### ⚙️ Miscellaneous Tasks

- Bump version to 0.53.5
## [0.53.4] - 2026-09-12

### 🐛 Bug Fixes

- *(driver)* Source MSVC env automatically on Windows for plain terminals

### ⚙️ Miscellaneous Tasks

- Bump version to 0.53.4
## [0.53.3] - 2026-09-12

### 🐛 Bug Fixes

- *(codegen)* Pin #line directives in variadic function preamble
- *(vscode)* Pass MSVC env to fun.exe so it emits MSVC-compatible C

### ⚙️ Miscellaneous Tasks

- Remove zig cc references from comments in driver and harness
- Bump version to 0.53.3
## [0.53.2] - 2026-09-12

### 🐛 Bug Fixes

- *(vscode)* Auto-source MSVC env for debug button on Windows

### ⚙️ Miscellaneous Tasks

- Bump version to 0.53.2

### 💼 Other

- *(fls,path,deps)* Windows compat for deps hover, completions, run, cache
## [0.53.1] - 2026-09-11

### 🐛 Bug Fixes

- *(cli)* Add fun add / fun deps update to -help output
- *(deps)* Fls completion for imp deps., validate fun add upfront
- *(cli)* _run_tests_captured now includes a failed test's stderr

### 📚 Documentation

- *(deps)* Use single-dash flags for fun add, matching every other CLI flag

### 🧪 Testing

- *(deps)* Split fls deps-hover test into 3, add failure diagnostics
- *(deps)* Add direct import_target/is_dir diagnostics for the Windows failure
- *(deps)* Isolate tokenizer path from resolve_import_path directly

### ⚙️ Miscellaneous Tasks

- Bump version to 0.53.1

### 💼 Other

- *(fls)* Is_dir() fallback in _resolve_specifier fixes deps hover on Windows
## [0.53.0] - 2026-09-11

### 🚀 Features

- *(deps)* Git-based dependency management via [deps] in fun.toml
- *(deps)* Resolve transitive [deps], real fetch bugs found along the way

### 🐛 Bug Fixes

- *(deps)* Correct the earlier WIP commit's diagnosis, no compiler bug
- *(deps)* Format the import_resolver test fixture, add env vars docs
- *(json)* Decode \r escape sequence in JSON string parser
- *(deps)* Replace POSIX-only mv/rm with cross-platform rename on Windows
- *(cli)* Executable_path qualifies bare names on Windows too, use backslash
- *(vscode)* Use `& ` invoker and PowerShell-safe escaping in terminal commands

### 📚 Documentation

- *(deps)* Clarify [lib] has nothing to do with [deps] sharing
- *(deps)* Note that fetching never verifies the repo is a Fun project

### ⚙️ Miscellaneous Tasks

- Bump version to 0.53.0

### 💼 Other

- *(deps)* [deps] manifest table with inline-table dependency entries
## [0.52.5] - 2026-09-10

### 🐛 Bug Fixes

- *(codegen)* Root-cause every remaining -g debug-info gap
## [0.52.4] - 2026-09-10

### 🐛 Bug Fixes

- *(codegen)* Root-cause the stacked-propagation double-evaluation bug

### 🚜 Refactor

- Re-tighten lookup_fit_variant's ?-chain now that the hoist bug is fixed
- Re-tighten the remaining safe ?-chain sites from the reverted batch
## [0.52.3] - 2026-09-10

### 🐛 Bug Fixes

- *(codegen)* Root-cause the receiver-chain generic-instantiation hoist leak
## [0.52.2] - 2026-09-10

### 🐛 Bug Fixes

- *(docs)* Remove a stale workaround note, verify and test the real fix
- *(fmt)* Keep a postfix ?/! glued to a chained field access
- *(fls)* Strip the pointer star from a propagated chain's own T
- *(fls)* Strip the pointer star everywhere a propagated T feeds a lookup
- Teach two more fit-subject resolvers about propagation and field access
- *(codegen)* Root-cause a nested-propagation double-eval and MSVC hoist leak

### 🚜 Refactor

- Inline the 5 originally-reverted ?-chain tightenings
- Inline further single-use ?-chain sites found surveying src/+fls/
- Dispatch directly on indexed elements, no bound pointer first
- Use the bare enum-variant shorthand for fls's own stdin sink

### ⚙️ Miscellaneous Tasks

- *(release)* Bump to 0.52.2

### ◀️ Revert

- Undo every ?-chain tightening still unsafe under MSVC
## [0.52.1] - 2026-09-09

### 🐛 Bug Fixes

- *(fls)* Resolve hover and dot-completion through an inline propagation receiver
- *(codegen)* Stop a stale hoist position from leaking across functions

### ⚙️ Miscellaneous Tasks

- *(release)* Bump to 0.52.1

### 💼 Other

- Fix an unformatted continuation line in navigation.fn
## [0.52.0] - 2026-09-09

### 🚀 Features

- *(codegen)* Support a propagation as a bare fit subject
- *(fls)* Resolve a propagation used as a fit subject in hover/completion

### 🐛 Bug Fixes

- *(codegen)* Dispatch a method on an indexed element reached through a chain
- *(parser)* Name the reserved word when it collides with a binding
- *(codegen)* Take the address of a call result or enum-variant shorthand
- *(codegen)* Let a method call resolve a global variable as its receiver
- *(parser)* Reject two adjacent expressions with no operator between them

### 📚 Documentation

- Document transitive imports and global private-name uniqueness as intended

### 🧪 Testing

- *(lexer)* Add regression coverage for the doubled-backtick escape
- *(typecheck)* Add regression coverage for the duplicate-symbol diagnostic

### ⚙️ Miscellaneous Tasks

- *(release)* Bump to 0.52.0
## [0.51.1] - 2026-09-09

### 🐛 Bug Fixes

- Postfix ?/! failed to hoist under MSVC when used inline as a receiver
- *(codegen)* '{ptr}'/'{raw}' skip Display dispatch, showing the raw pointer
- Restore expr?.field inline-receiver and fix {ptr} MSVC dispatch
- *(warnings)* Normalize resolved import path before comparing against pos.filename
- Restore expr?.field inline-receiver and fix {ptr} MSVC dispatch (#112)
- *(editors)* Highlight postfix '?' as an operator, matching '!'

### 🚜 Refactor

- Adopt postfix ?/! propagation across src/, where the shape matches exactly

### ⚙️ Miscellaneous Tasks

- *(release)* Bump to v0.51.1

### ◀️ Revert

- Drop expr?.field inline-receiver support, real MSVC crash on Windows CI
## [0.51.0] - 2026-09-08

### 🚀 Features

- *(lang)* Function values as first-class - checked at every call site, valid everywhere a type is
- *(lang)* Postfix ? and ! operators for Option/Result propagation

### 🐛 Bug Fixes

- *(fls)* Switch stdio to binary mode on Windows to fix LSP framing
- *(fls)* Fix LSP header framing on Windows via runtime backend check
- *(codegen)* Infer generic type params from &arg and let-copied identifiers
- *(semantics)* Report missing_return and unused-const warnings at their own position; type-check top-level consts
- *(fls)* Sizeof/fork in completion, self. filtering, no completion inside comments
- *(fls)* Let-inferred function value hovers its own type, not the referenced function's declaration
- Postfix operator precedence after a method chain, private-method resolution, and formatter spacing
- Generic function call chaining, and postfix operators before another unary op

### 📚 Documentation

- *(examples)* Add postfix ?/! propagation examples

### 🚜 Refactor

- *(lang)* Convert two real call sites to postfix ! propagation

### ⚙️ Miscellaneous Tasks

- *(release)* Bump to v0.51.0
## [0.50.4] - 2026-09-06

### 🐛 Bug Fixes

- *(installer)* Drop stale zig default from the Windows MSI and portable package
- *(fls)* Resolve a bare '.{...}' compound-literal shorthand field's own hover
- *(codegen)* Guard nil pointers in Display-dispatched varargs
- *(fls)* Render a generic type param's own declared constraint in hover
- *(codegen)* Increase MSVC test-binary stack from 8 MB to 64 MB

### ⚙️ Miscellaneous Tasks

- *(ci)* Drop the Windows -lm bootstrap bridge, no longer needed
## [0.50.3] - 2026-09-05

### 🐛 Bug Fixes

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

### ⚙️ Miscellaneous Tasks

- *(release)* Bump to v0.50.3
## [0.50.2] - 2026-09-04

### 🚀 Features

- *(cli)* Read fun.toml with library, binary, and mixed packages
- *(stdlib)* Parse TOML sections and arrays of tables
- *(cli)* Compile and run programs, with build-time constants from the manifest
- *(cli)* Build a package from its manifest
- *(cli)* Run a file's test blocks with fun test
- *(codegen)* Back the process bindings on Windows
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
- *(semantics)* Check calls made through a receiver
- *(semantics)* Check impl bodies, quirk conformance, and enum values
- *(semantics)* Reject unknown callees, value sizeof, and non-bin conditions
- *(semantics)* Hold generic calls and quirk impls to what they declare
- *(semantics)* Follow the arguments an instantiation supplies
- *(semantics)* Check instantiations, inferred ones included
- *(semantics)* Report what a program probably did not mean
- *(semantics)* Notice races, deadlocks, overflows, and out-of-range literals
- *(semantics)* Hold a name to what the file declaring it offers
- *(fls)* Speak the language server protocol
- *(fls)* Report diagnostics, hover, and go to definition
- *(fls)* List what a document declares
- *(fls)* Find references, rename, and complete
- *(fls)* Format a document, and complete with snippets
- *(codegen)* Carry a function-typed argument through an async call
- *(typecheck)* Reject a written zero divisor and a mismatched fit branch
- *(parser)* Measure a pointer type with sizeof
- *(typecheck)* Hold a global and a field to what their file offers
- *(parser)* Forward-reference a type in a compound initializer
- *(codegen)* Drive 'for x : c' via a user Iterator quirk impl
- *(codegen)* Check format()'s argument count against its placeholders
- *(parser,codegen)* Parse and emit inline assembly (asm statement)
- *(selfhost)* Run every test block under a directory, not just one file
- *(selfhost)* Port fuzz-mode codegen and the fun fuzz subcommand
- *(selfhost)* Finish self-hosting, retire the Zig toolchain
- *(fls)* Hover and go-to-definition for enum variants and fit payload bindings
- *(fls)* Add textDocument/signatureHelp
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
- *(fmt)* Wrap an over-long ||/&& chain, filling each line like fit arms
- *(cli)* Shorten fun init's project kinds to lib/exe/mix, and write a .gitignore
- *(fls)* Hover a number literal to see it in decimal, hex, binary, and octal
- *(codegen)* Emit #line directives for -g, restoring native debugging
- *(website)* Tabbed stdlib module view, syntax highlighting sourced from the editor themes
- *(website)* Split the docs into topic-based tabs, not two giant pages
- *(website)* Redesign the sidebar nav, drop the redundant right-side TOC

### 🐛 Bug Fixes

- *(cli)* Build and run the same way on all three platforms
- *(cli)* Drop an unused import
- *(codegen)* Name the node a failed compile choked on, and accept warning control
- *(codegen)* Give a test body its own function state, and report where a failure came from
- *(cli)* Keep build output under fun-out, and stop tracking generated C
- *(lexer)* Record whether whitespace follows a token
- *(lexer)* Keep whitespace that a lookahead consumed
- *(cli)* Write character literals as they were written
- *(imports)* Keep an absolute path absolute
- *(parser)* Leave no value pointer unset on a declaration that has none
- *(lexer)* Let a raw string hold a backtick
- *(imports)* Ask where the standard library is rather than assume
- *(selfhost)* Drop imports nothing uses
- *(warnings)* Judge a real file the way the reference does
- *(typecheck)* Say when a call names a method a type does not have
- *(warnings)* Check a fit written in shorthand
- *(typecheck)* Enforce a method's own generic bound
- *(typecheck)* Judge visibility on an alias-qualified call
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
- *(codegen)* Include time.h explicitly, close std.c.* header gap
- *(selfhost)* Elastic scheduler pool, bounded concurrent import preload
- *(selfhost)* Give kill() a real Windows implementation
- *(ci)* Make the asm-arch check bootstrap-safe, lint with the built binary
- *(codegen)* Splice a nested generic method's own prototype at file scope
- *(codegen)* Drop redundant parens on if/while conditions, define Windows pid_t
- *(codegen)* Splice lazy prototypes at function scope, not block scope
- *(ci)* Pass a token to setup-fun so it doesn't hit the anonymous API limit
- *(codegen)* Give a plain method and a same-named quirk method separate identities
- *(codegen)* Ensure a by-value generic-field substitution's plain type is emitted first
- *(fls)* Stop mangling non-ASCII bytes into invalid JSON escapes
- *(fls)* Hover/definition for methods, qualified variants, doc comments, missing keyword docs
- *(fls)* Method hover was still returning null, and resolve generic variant payloads to concrete types
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
- *(fls)* Stop the workspace symbol table from outliving a closed document's own strings
- *(codegen)* Rename TokenType, add a Windows clock_gettime, use dot-shorthand throughout
- *(stdlib)* Stop formatting a num with %lld, portable only by accident
- *(codegen)* Give the fork-scheduler's own prelude the clock_gettime shim too
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
- *(fls)* Resolve generic calls, arithmetic, await, and chains through parens in let-inference
- *(fls)* Give fun.toml's own PACKAGE_NAME/PACKAGE_VERSION hover and completion support
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

### 📚 Documentation

- *(tests)* Say why the watchdog test is still waiting
- *(tests)* Correct what the generic-compound-quirk gap actually is
- Drop -- asides from this session's own comments
- *(selfhost)* Close deep-expression stack-guard gap note
- Describe the elastic scheduler pool and Mutex/WaitGroup safety
- Describe the directory-wide fun test/fuzz forms and env_or
- *(fls)* Document and test the deliberate refusal of a ranged edit with no baseline
- *(examples)* Exercise implicit-typed const bindings, not just explicit
- *(ci)* Update every remaining compiler/ reference to src/
- *(cli)* Document -test/-fuzz/-fuzz-target in help text
- Fix the C compiler selection docs, stale since self-hosting
- Document the per-test/per-fuzz-target commands, and fork in the async debugging notes
- Sweep stale Zig references and dead cross-links, link sections

### ⚡ Performance

- *(fls)* Read a document once per revision
- *(fls)* Parse an unchanged import once, not once per keystroke

### 🚜 Refactor

- *(io)* Let a sink read as well as write
- *(fls)* Name the stream at the call rather than binding it first
- Rename compiler/ to src/
- *(cli)* Rename the manifest's [[bin]] target to [[exe]]

### 🧪 Testing

- *(fmt)* Cover the formatter with its own cases
- *(selfhost)* Write the tests that were left unwritten
- *(selfhost)* Run the programs whose behavior was only asserted about
- *(selfhost)* Hand back what a run produced, not only its output
- *(selfhost)* Run the last test that was only described
- *(selfhost)* Read a float literal written with an exponent
- *(selfhost)* Run the quirk coercion shapes as real tests
- *(fit)* Close all remaining fit_tests.fn gap markers
- *(selfhost)* Close statement-termination gap note
- *(selfhost)* Close the last gap marker
- *(fls)* Cover a multi-dot ('....') parent-traversal import
- *(fls)* Use the raw-string doubled-backtick escape, not string concat
- *(fls)* Verify dot-completion merges a method from a different file
- *(warnings)* Cover blocking_fork_deadlock, the one warning id with no test at all
- *(fls)* Lock in the fuzz block data/len hover behavior on inception

### ⚙️ Miscellaneous Tasks

- Add self-hosted CI validation, describe Fun as self-hosted
- Drop the Force clang on Linux workaround
- Two-stage Windows build — bootstrap with clang then recompile with cl
- Load MSVC env before fun build on Windows
- *(ci)* Revert forced FUN_CC=cl on Windows build step
- Drop leftover zig-out/zig-cache gitignore entries
- *(release)* Bump to v0.50.1

### 🛡️ Security

- *(deps-dev)* Bump fast-uri from 3.1.5 to 3.1.7 in /editors/vscode in the npm_and_yarn group across 1 directory (#103)

### 💼 Other

- Declare fls as a binary the manifest builds
- Bring in the worker-thread stack-size fix from main (v0.46.4)
- Bring in the top-level statement-termination fix from main
- Bring in the cli.fn -- pointer-comparison fix from main (v0.46.9)
- Run the formatter over files the lint step flagged
- *(deps-dev)* Bump fast-uri
- *(deps)* Bump the npm_and_yarn group across 2 directories with 1 update
- *(deps)* Bump the npm_and_yarn group across 2 directories with 1 update (#104)
- Self-hosted Fun toolchain (#102)
## [0.46.16] - 2026-09-03

### 🐛 Bug Fixes

- *(cli)* Rename manifest's [[bin]] target to [[exe]]
## [0.46.15] - 2026-09-02

### 🐛 Bug Fixes

- *(codegen)* Fix print() routing and qrecv/frame scoping bugs
- *(cli,codegen,tests)* Full MSVC support for FUN_CC=cl fun build

### ⚙️ Miscellaneous Tasks

- Bump test timeout-minutes 20 -> 35 for macOS
## [0.46.14] - 2026-09-01

### 🐛 Bug Fixes

- *(codegen)* Eliminate __auto_type and GNU statement expressions from generated C
## [0.46.13] - 2026-08-25

### 🐛 Bug Fixes

- *(codegen)* Give Windows a real clock_gettime for std.channel's own deadline math
- *(codegen)* Guard the Windows clock_gettime shim from MinGW's own real one
## [0.46.12] - 2026-08-25

### 🚀 Features

- *(cli)* Inject PACKAGE_NAME/PACKAGE_VERSION into fun build targets

### 🐛 Bug Fixes

- *(codegen)* Resolve a call embedded mid-chain when lowering method calls
## [0.46.11] - 2026-08-19

### 🐛 Bug Fixes

- *(stdlib)* StringBuilder leaks a fragment on every append
## [0.46.10] - 2026-08-16

### 🐛 Bug Fixes

- *(codegen)* Give Windows thread/process compat a real pid_t and clock
## [0.46.9] - 2026-08-16

### 🐛 Bug Fixes

- *(stdlib)* Compare -- by content, not pointer, in cli_parse_ext
## [0.46.8] - 2026-08-15

### 🚀 Features

- *(stdlib)* Process spawn/kill/sleep primitives, fix a real env() crash

### 🐛 Bug Fixes

- *(codegen)* Include windows.h before the new sleep helper uses Sleep
- *(codegen)* Give kill() a real Windows implementation
## [0.46.7] - 2026-08-15

### 🚀 Features

- *(cli)* Run every test/fuzz block under a directory, not just one file
## [0.46.6] - 2026-08-15

### 🐛 Bug Fixes

- *(concurrency)* Elastic scheduler pool, eager Mutex/CondVar init, guarded WaitGroup count
## [0.46.5] - 2026-08-15

### 🐛 Bug Fixes

- *(parser)* Require a trailing ';' on a bare top-level expression
## [0.46.4] - 2026-08-15

### 🐛 Bug Fixes

- *(codegen)* Size every worker thread's stack explicitly
## [0.46.3] - 2026-08-14

### 🐛 Bug Fixes

- *(stdlib)* Read the exponent in a decimal
## [0.46.2] - 2026-08-14

### 🐛 Bug Fixes

- *(codegen)* Let a program name a variable argv
- *(codegen)* Give Windows a setenv of its own
## [0.46.1] - 2026-08-13

### 🐛 Bug Fixes

- *(lexer)* Let a raw string hold a backtick
## [0.46.0] - 2026-08-13

### 🚀 Features

- *(stdlib)* Sections, flags, directories, sink reads, and hexadecimal
## [0.45.5] - 2026-08-13

### 🐛 Bug Fixes

- *(warnings)* Count a variant constant as using the enum's import
## [0.45.4] - 2026-08-12

### 🐛 Bug Fixes

- *(codegen)* Stop reading past the end of a mangled name
## [0.45.3] - 2026-08-12

### 🐛 Bug Fixes

- *(codegen)* Keep an element's pointer depth in the iterator's option type
- *(cli)* Build a manifest from a given directory

### 🎨 Styling

- Run zig fmt over the cli tests
## [0.45.2] - 2026-08-12

### 🐛 Bug Fixes

- *(codegen)* Keep a field receiver's type arguments when chaining
## [0.45.1] - 2026-08-12

### 🐛 Bug Fixes

- *(fmt)* Keep a raw string's contents out of comment alignment
## [0.45.0] - 2026-08-12

### 🚀 Features

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

### 🐛 Bug Fixes

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

### 📚 Documentation

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

### ⚡ Performance

- *(fls)* Fix runaway CPU and cascading test timeouts

### 🚜 Refactor

- *(stdlib)* Adopt const bindings, genericize ok() to Result<T, E>
- *(selfhost)* Use multiline raw strings for write_prelude's static C text

### 🧪 Testing

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

### ⚙️ Miscellaneous Tasks

- Bump test step timeout to 20 minutes

### 🛡️ Security

- *(deps-dev)* Bump js-yaml from 4.2.0 to 4.3.1 in /editors/vscode in the npm_and_yarn group across 1 directory (#101)

### 💼 Other

- *(deps-dev)* Bump js-yaml
## [0.44.0] - 2026-07-24

### 🚀 Features

- *(generics)* Impl methods can declare their own type parameter

### 🐛 Bug Fixes

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

### 🧪 Testing

- *(codegen)* Confirm self-recursive constrained generic function already works
## [0.43.0] - 2026-07-22

### 🐛 Bug Fixes

- *(codegen)* Torture-test fallout — Display-via-deref dispatch, exhaustive-fit false positive, enum/workspace-scan collision
- *(parser,codegen)* Uninitialized fit has_default_branch (real UB); cross-file private-function collisions

### 🧪 Testing

- *(fls)* Cover chained unwrap_or() on a function-parameter receiver + after incremental edits

### ⚙️ Miscellaneous Tasks

- *(changelog)* Update CHANGELOG for version 0.42.4 with recent fixes and dependency bumps
- Remove unused serde import from std.json and std.toml
## [0.42.4] - 2026-07-21

### 🐛 Bug Fixes

- *(codegen)* Mangle generic compound type before Display auto-dispatch resolution
## [0.42.3] - 2026-07-21

### 🐛 Bug Fixes

- *(fls)* Substitute concrete generic args in quirk missing-method diagnostics; fix UTF-16/byte position desync
## [0.42.2] - 2026-07-21

### 🐛 Bug Fixes

- *(fls)* Correct completion misfires and codegen edge cases; add underscore numeric literals
## [0.42.1] - 2026-07-21

### 🐛 Bug Fixes

- *(vscode)* Restore compile after vscode-languageclient v10 bump
- *(fls)* Substitute concrete generic args in fit-branch variant hover
## [0.42.0] - 2026-07-20

### 🚀 Features

- Wire ErrorKind through stdlib errors and merge constrained-generic duplicates

### ⚙️ Miscellaneous Tasks

- Refactor serialization quirks to use generic To<T> and From<T> mechanisms
## [0.41.1] - 2026-07-17

### 🚀 Features

- Implement global search modal and enhance search functionality

### 🐛 Bug Fixes

- Improve handling of module and version readiness in App component

### 🚜 Refactor

- Simplify result handling in channel and json implementations

### 🧪 Testing

- Refine expectations in std.log aliased import tests
## [0.41.0] - 2026-07-16

### 🚀 Features

- Add concurrency lints and align Fun Web light themes

### ⚙️ Miscellaneous Tasks

- Update CHANGELOG with new features and improvements for version 0.40.0
## [0.40.0] - 2026-06-14

### 🚀 Features

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

### ⚙️ Miscellaneous Tasks

- Refactor Result and Option handling in stdlib
- Refactor stdlib synchronization and threading code to use 'nil' instead of 'NULL'
- Refactor std library for improved error handling and functionality
- Refactor variable declarations to use 'let' instead of type declarations in stdlib
- Refactor channel and file handling APIs for improved error handling and consistency
- *(docs)* Enhance documentation across standard library modules
## [0.30.2] - 2026-06-03

### 🚀 Features

- *(parser)* Implement O(1) significant-token lookahead for improved performance
## [0.30.1] - 2026-06-02

### 🐛 Bug Fixes

- Unused_import on non-aliased imported function calls

### 🧪 Testing

- Increase warm save threshold from 150ms to 200ms
## [0.30.0] - 2026-05-28

### 🚀 Features

- Add zig.testArgs configuration to settings
- Add new warning controls and refactor existing tests
- Add unused variable expect example to expected fail cases
## [0.29.1] - 2026-05-05

### 🚀 Features

- *(formatting)* Implement format-on-save cache hit for improved performance

### 🐛 Bug Fixes

- *(tests)* Update format-on-save cache hit threshold to 200 ms
## [0.29.0] - 2026-05-05

### 🚀 Features

- *(array)* Add support for multi-dimensional arrays and enhance transpilation for array types
- *(fls)* Implement diagnostic caching to improve performance and reduce compile time
- *(cli)* Add -fmt-check flag to verify formatting without modifying files
- Add run and debug commands for Fun language in VSCode extension
- *(generics)* Add constrained impl params (T: num | dec) and update vec/string stdlib

### 🐛 Bug Fixes

- *(fls)* Use `fun` language id in hover code fences and improve semantic token classification
- *(editors)* Fix vim E867 syntax error, set 2-space indent across editors, update neovim docs to 0.11+ LSP API
- *(build)* Add link_libc option to all modules in build process
- *(transpiler)* Improve handling of generic instantiations and memory allocation
- Replace std.debug.print with proper IO in production code
- *(examples)* Fix asm_arch_specific expected-fail handling in run scripts
- *(fls,fmt)* Support constrained impl generics and restore field go-to-definition
- *(codegen)* Correct defer #line mapping for function-scope defers
- *(codegen)* Emit semicolon for declaration-only function prototypes

### ⚡ Performance

- *(fls)* Combine format+diagnostics into single subprocess on save

### 🚜 Refactor

- *(fls)* Split monolithic main.zig into modular structure

### ⚙️ Miscellaneous Tasks

- Bump Zig version to 0.16.0 in CI/release workflows
## [0.28.8] - 2026-04-13

### 🚀 Features

- Add withBasePath function to handle base URL and improve version content fetching
- Enhance Fun Web color theme with additional syntax highlighting for regex, keywords, and various types
- Add operator and punctuation highlighting across various editors and themes
## [0.28.7] - 2026-04-13

### 🚀 Features

- Add Fun Web color scheme and enhance syntax highlighting
## [0.28.6] - 2026-04-06

### 🚀 Features

- Enhance defer semantics and add comprehensive tests for defer behavior in various contexts
## [0.28.5] - 2026-04-06

### 🚀 Features

- *(tests)* Enhance e2e tests for async function completion and definition resolution
## [0.28.4] - 2026-04-06

### 🚀 Features

- Add support for variadic function signatures and corresponding tests
- Enhance documentation and return codes across synchronization and threading modules

### ⚙️ Miscellaneous Tasks

- Update CHANGELOG for version 0.28.3 with new features and improvements
## [0.28.3] - 2026-04-06

### 🚀 Features

- *(tests)* Add end-to-end test for let inference with async call and address argument
## [0.28.2] - 2026-04-06

### 🚀 Features

- Add async thread clock ticks example and update README

### ⚙️ Miscellaneous Tasks

- Update CHANGELOG for version 0.28.1 and improve formatting
## [0.28.1] - 2026-04-05

### 🚀 Features

- *(tests)* Add end-to-end tests for let await pointer chain inference
- *(tests)* Add test for async await statement transpilation and execution
- Enhance module summary normalization and improve mobile drawer functionality
- Implement CRLF normalization in output for consistency

### ⚙️ Miscellaneous Tasks

- Update CHANGELOG for version 0.28.0 and improve formatting
- Add tests for async quirks, generic inference, and typechecking
## [0.28.0] - 2026-04-05

### 🚀 Features

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

### 🐛 Bug Fixes

- Update clock_gettime calls to use raw pointers for ChannelAbsTime handling
- Update printf format specifiers to use %lld for long long integers

### 📚 Documentation

- Update FAQ to clarify default indexing behavior and parser settings

### ⚙️ Miscellaneous Tasks

- Enhance channel functionality and testing
- Update CHANGELOG with recent enhancements, fixes, and documentation updates
- Update CHANGELOG with recent enhancements, fixes, and documentation updates
- Improve code formatting and spacing across multiple files

### 💼 Other

- Harden indexing crash path and document parse mode
## [0.27.1] - 2026-04-01

### 🚀 Features

- *(docs)* Update language reference with `allow` and `expect` keywords
## [0.27.0] - 2026-04-01

### 🚀 Features

- Implement warning control mechanisms with `allow` and `expect` statements
- *(tests)* Add end-to-end tests for warning IDs completion with allow and expect keywords
## [0.26.2] - 2026-04-01

### 🚀 Features

- *(docs)* Enhance documentation comments across various modules for clarity and consistency
## [0.26.1] - 2026-04-01

### 🐛 Bug Fixes

- *(release)* Ensure artifacts directory is created before building portable zip

### ⚙️ Miscellaneous Tasks

- Update CHANGELOG for upcoming release with new fixes and enhancements
## [0.26.0] - 2026-04-01

### 🚀 Features

- *(examples)* Add examples for private quirk method access and visibility rules
- *(codegen)* Enhance transpiler to support aliased imports and function resolution
- *(release)* Add portable zip support for Windows and update README
- Enhance Markdown rendering with heading permalinks and copy functionality

### 🐛 Bug Fixes

- *(codegen)* Scope import alias resolution to the owning module
- *(fls)* Infer let array literal hover types in LSP
- *(fls)* Harden let inference under incomplete code and dangling operators
- *(fls)* Preserve imported enum let inference and harden incomplete-expression parsing
- *(formatting)* Adjust spacing around operators and ensure consistent formatting in examples
- *(impl)* Update implementation syntax to use 'as' for quirks
- *(cli,codegen,stdlib)* Improve Linux C build compatibility and reduce gcc warnings
## [0.25.3] - 2026-03-23

### 🚀 Features

- Enhance GitHub Pages experience by disabling runtime execution and updating related messages
## [0.25.2] - 2026-03-22

### 🚀 Features

- Add syntax highlighting for Fun language reference and integrate favicon
## [0.25.1] - 2026-03-22

### 🚀 Features

- Update CHANGELOG for version 0.25.0 with new features and dependency bumps
## [0.25.0] - 2026-03-22

### 🚀 Features

- Implement alias handling for compound types and enhance transpiler with canonical name resolution
- Introduce Result type and enhance error handling across stdlib
- Implement best-effort type inference for let variables in LSP indexing
- Add cleanup functionality to example scripts and enhance cache management
- Enhance multi-file snippet support and improve markdown rendering
- Enhance stdlib module exploration with modal support and improved styling
## [0.24.1] - 2026-03-02

### 🚀 Features

- Enhance Windows compiler configuration and cleanup in uninstall script
- Enhance symbol grouping in documentation with collapsible sections and styling
## [0.24.0] - 2026-03-02

### 🚀 Features

- Enhance asm block handling to support computed operands and preserve formatting
## [0.23.1] - 2026-03-01

### 🚀 Features

- Update asm block handling to preserve newlines and add corresponding test case

### 🐛 Bug Fixes

- Update asm block in test to remove architecture specification
## [0.23.0] - 2026-03-01

### 🐛 Bug Fixes

- Update import alias in e2e test and adjust expected completion label
## [0.22.5] - 2026-03-01

### 🚀 Features

- Enhance parser to support qualified user-defined types and improve type segment parsing
## [0.22.3] - 2026-03-01

### 🚀 Features

- Update search input to be sticky and remove sticky styling from detail card for improved layout
## [0.22.2] - 2026-03-01

### 🚀 Features

- Enhance MarkdownWithPlayground component with sourcePath prop and improve link handling; update styles for better accessibility and responsiveness
## [0.22.1] - 2026-03-01

### 🚀 Features

- Remove environment configuration from GitHub Pages deployment step
## [0.22.0] - 2026-03-01

### 🚀 Features

- Enhance Fun language with new features and type inference
- Enhance type checking for enums as numeric values and improve transpiler logic
- Add example for explicit main exit status and enhance transpiler logic for return values
- Add support for import aliases in transpiler
- Enhance socket and network functionality with additional API methods
- Add content generation and synchronization scripts for Fun language reference
- Add environment variable for FUN_STDLIB_DIR in examples job
- Update run_examples.sh to use FUN_STDLIB_DIR environment variable and capture failure details
- Improve hash function in Map implementation with modular arithmetic

### 🐛 Bug Fixes

- Correct command for running examples in README
## [0.21.2] - 2026-02-05

### 🚀 Features

- Enhance enum exhaustiveness checking in transpile process

### ⚙️ Miscellaneous Tasks

- Enable conventional commits in cliff.toml
## [0.20.3] - 2026-02-04

### 🚀 Features

- Add GitHub Actions section to README for CI installation instructions
- Update C compiler selection details in README for macOS/Linux and Windows
- Update cache directory structure to use .fun-cache for CLI operations
## [0.20.2] - 2026-02-04

### 🚀 Features

- Update compiler settings to use gcc for linux and macos and MSVC for windows instead of zig in installation scripts
## [0.20.1] - 2026-02-04

### 🚀 Features

- Enhance transpilation process with generic compound specialization support
## [0.20.0] - 2026-02-04

### 🚀 Features

- Add editor support documentation and syntax highlighting for Fun language
- Update .gitattributes for Zig syntax highlighting and enhance README with compiler selection and editor support sections
## [0.19.1] - 2026-02-04

### 🚀 Features

- Add .gitattributes to specify linguist language for .fn files
## [0.19.0] - 2026-02-04

### 🚀 Features

- Enhance stdlib with new functionalities and improvements
- Add support for generic types in syntax highlighting
- Add assert statement with optional message and update related examples
## [0.18.2] - 2026-02-04

### 🧪 Testing

- Add end-to-end test for generic type member completion (Vec<T>)
## [0.18.1] - 2026-02-04

### 🚀 Features

- Enhance install script to support fallback for POSIX shells and add compiler environment variables
## [0.18.0] - 2026-02-04

### 📚 Documentation

- Update README and documentation for 64-bit numeric types and add reference.md
- Enhance documentation for standard library and add POSIX socket support
## [0.17.1] - 2026-02-03

### 🐛 Bug Fixes

- Update return values in IO and Result functions to use boolean types
## [0.17.0] - 2026-02-03

### 🚀 Features

- Enhance keyword and datatype handling, improve visibility and access control
- Update C stdlib imports to use 'std.c.def' for compatibility
- Enhance keyword and datatype handling, improve visibility and access control (#69)
- Add inline assembly support with volatile options and architecture guards
- Add inline assembly support with volatile options and architecture guards (#71)
## [0.16.1] - 2026-02-02

### 🚀 Features

- Refactor defer block handling in parser and enhance demo functions
## [0.16.0] - 2026-02-02

### 🚀 Features

- Add defer keyword support with LIFO execution and update documentation
- Add defer keyword support with LIFO execution and update documentation (#68)
## [0.15.5] - 2026-02-02

### 🚀 Features

- Implement inferDeclTypeBeforeName function and enhance exe path resolution in tests
## [0.15.4] - 2026-02-02

### 🚀 Features

- Add insertText and filterText fields to CompletionItem in LspServer
## [0.15.3] - 2026-02-02

### 🚀 Features

- Enhance enum support with shorthand access and update documentation
## [0.15.2] - 2026-02-01

### 🚀 Features

- Add support for referencing enum types before declaration in codegen

### 🐛 Bug Fixes

- Correct indentation in LspServer struct for improved readability
## [0.15.1] - 2026-02-01

### 🚀 Features

- Add LSP support for enum dot shorthand completion, hover, and definition
- Add LSP support for enum dot shorthand completion, hover, and definition (#67)
## [0.15.0] - 2026-01-05

### 🚀 Features

- Implement `sizeof` operator support with hover, completion, and signature help
- Add enum support with shorthand syntax and enhance parsing
- Improve token emission formatting and ensure spacing for operators before dot shorthand
- Update CHANGELOG.md to reflect recent changes and enhancements
## [0.14.3] - 2026-01-05

### 🚀 Features

- Add support for `sizeof` operator and related error handling in transpilation
## [0.14.2] - 2026-01-05

### 🚀 Features

- Add custom import namespace hover functionality to display README content
- Add new transpilation error types and enhance type checking tests for variadic arguments
## [0.14.1] - 2026-01-04

### 🚀 Features

- Enhance fit statement exhaustiveness checks and add related tests
- Add parameter handling to signature help and enhance related tests
## [0.14.0] - 2026-01-04

### 🚀 Features

- Enhance environment variable handling in installer scripts for better path resolution
- Add diagnostics for returning address of local variables and implement related tests
- Improve module and directory handling in LSP server for better file resolution

### 📚 Documentation

- Update Zig version recommendation in README to reference build.zig.zon
## [0.13.3] - 2026-01-04

### 🚀 Features

- Update .gitignore and add initial implementation of Fun Language Server
## [0.13.2] - 2026-01-04

### 🚀 Features

- Update README to clarify prerequisites and enhance getting started instructions
- Enhance debugging options and logging for the Fun language server
## [0.13.1] - 2026-01-04

### 🚀 Features

- Enhance symbol collection to support pointer and reference types in function parameters
- Enhance build process to stage test binaries and improve error handling in imports
- Enhance function and variable type handling in LSP server responses
## [0.13.0] - 2026-01-04

### 🚀 Features

- Enhance formatting for pointer types in function signatures
## [0.12.12] - 2026-01-04

### 🚀 Features

- Enhance formatting for pointer and address-of spacing in CLI
## [0.12.11] - 2026-01-04

### 🚀 Features

- Improve version extraction and validation in release workflows
## [0.12.10] - 2026-01-04

### 🚀 Features

- Enhance release workflow with version verification and tag resolution
## [0.12.9] - 2026-01-04

### 🚀 Features

- Enhance release workflow to correctly handle release tags
## [0.12.8] - 2026-01-04

### 🚀 Features

- Improve version handling in CLI and update usage instructions
## [0.12.7] - 2026-01-04

### 🚀 Features

- Enhance LspServer to support stdlib namespace completions and hover information
- Add version option to CLI and update usage instructions
- Add version tagging to build process in release workflow
## [0.12.6] - 2026-01-03

### 🚀 Features

- Enhance LspServer and TranspileProcess to improve file handling and error reporting on Windows
## [0.12.5] - 2026-01-03

### 🚀 Features

- Enhance LspServer to support multiple executable directory layouts for stdlib root detection
## [0.12.4] - 2026-01-03

### 🚀 Features

- Enhance LSP server to support directory walking for stdlib root detection; improve error handling for unknown function calls
## [0.12.3] - 2026-01-03

### 🚀 Features

- Enhance LSP server to resolve stdlib paths and improve import handling; add operator syntax highlighting
## [0.12.2] - 2026-01-03

### 🚀 Features

- Enhance installation and uninstallation scripts to manage FUN_STDLIB_DIR environment variable
- Add guards and separate functions for emitting impl bodies and vtables in TranspileProcess
- Enhance symbol indexing to include locals and parameters in impl methods
- Update isStdlibRoot function to handle absolute paths and improve directory validation
## [0.12.1] - 2026-01-03

### 🚀 Features

- Update install and uninstall scripts to handle 'fls' binary
## [0.12.0] - 2026-01-03

### 🚀 Features

- Add debug logging and error handling for argument and body parsing in ParseProcess
- Add stdlib root path handling and cleanup in LspServer
## [0.11.7] - 2026-01-03

### 🚀 Features

- Enhance error handling for temporary directory and lexer/parser processes
## [0.11.6] - 2026-01-03

### 🚀 Features

- Improve temporary file handling in buildIndexFromText function
- Implement temporary directory cleanup for fls
## [0.11.5] - 2026-01-03

### 🐛 Bug Fixes

- Update publisher field in package.json to "omdxp"
## [0.11.4] - 2026-01-03

### 🚀 Features

- Update display name to "Fun (FLS) for VS Code" for clarity
## [0.11.3] - 2026-01-03

### 🚀 Features

- Update display name to "Fun Language Support" for clarity
## [0.11.2] - 2026-01-03

### 🚀 Features

- Add package path and base URLs for VSCE publish command in workflow
## [0.11.1] - 2026-01-03

### 🚀 Features

- Add base URL handling for README links in VS Code extension packaging
## [0.11.0] - 2026-01-03

### 🚀 Features

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

### 📚 Documentation

- Update README files for consistency and clarity; enhance module descriptions

### ⚙️ Miscellaneous Tasks

- Skip unstable LSP tests in CI workflow and update main_test.zig
## [0.10.0] - 2026-01-01

### 🚀 Features

- Enhance C standard library compatibility with new examples and typedef support
- Update time_format_now example to use time_t for epoch seconds and human-readable format
- Add support for out-of-order function definitions by emitting prototypes
## [0.7.0] - 2026-01-01

### 🚀 Features

- Add read-write initialization for TranspileProcess to support in-place file modifications
## [0.6.3] - 2026-01-01

### 🚀 Features

- Ensure INSTALLFOLDER is created before adding to PATH
## [0.6.2] - 2026-01-01

### 🚀 Features

- Enhance WiX build process with improved logging and argument handling
## [0.6.1] - 2026-01-01

### 🚀 Features

- Normalize version tags for WiX Product/@Version in release workflow
## [0.6.0] - 2026-01-01

### 🚀 Features

- Enhance parser and semantics for variadic functions and raw types
- Add new for loop syntax support and corresponding tests
- Add support for passing program arguments to compiled executables
## [0.3.1] - 2026-01-01

### 🚀 Features

- Enhance transpiler and parser error handling with improved position tracking
## [0.3.0] - 2026-01-01

### 🚀 Features

- Enhance run_examples.ps1 to dynamically resolve RepoRoot if not provided
- Add identifier sanitization for transpilation process
- Add caching for quirk signature hashes in TypeRegistry
## [0.2.0] - 2026-01-01

### 🚀 Features

- Add tests for function calls with varying argument counts and types
- Enhance language support with decimal type and character literals, update lexer and parser for new number handling
- Add support for compounds, quirks, and implementations
- Add support for compounds, quirks, and implementations (#62)
## [0.1.15] - 2025-12-31

### 🚀 Features

- Rename built binaries to include target in release workflow
## [0.1.14] - 2025-12-31

### 🚀 Features

- Update release workflow to include both 'fun' and 'fun.exe' artifacts
## [0.1.13] - 2025-12-31

### 🚀 Features

- Remove update-changelog job from release workflow
- Update CHANGELOG.md to reflect recent changes and enhancements
## [0.1.11] - 2025-12-31

### 🚀 Features

- Remove debug step for GH_PAT in release workflow
## [0.1.10] - 2025-12-31

### 🚀 Features

- Add debug step to check GH_PAT environment variable in release workflow
## [0.1.9] - 2025-12-31

### 🚀 Features

- Update git remote URL to use personal access token for pushing changes
## [0.1.7] - 2025-12-31

### 🚀 Features

- Update release workflow to use personal access token and add cliff configuration
## [0.1.5] - 2025-12-31

### 🚀 Features

- Simplify git-cliff installation method in release workflow
## [0.1.3] - 2025-12-31

### 🚀 Features

- Fix git-cliff installation path in release workflow
## [0.1.2] - 2025-12-31

### 🚀 Features

- Fix git-cliff installation path in release workflow
## [0.1.1] - 2025-12-31

### 🚀 Features

- Update git-cliff installation method and build configuration
## [0.1.0] - 2025-12-31

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
- Add job to update and commit CHANGELOG.md on release
- Update git-cliff installation to version 2.11.0

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

### 📚 Documentation

- Add docs for `LexProcess` structure
- Lexer strings functions
- Add token_make_character documentation
- Add start_expression documentation
- Add documentation for the used functions
- Add detailed documentation for parser and transpiler scope functions

### 🚜 Refactor

- Improve deinit function and simplify main loop printing
- Remove unused test for parsing if statements
- Enhance scope management in transpiler and parser
- Streamline node creation and scope entity handling in parser and transpiler
- Remove escape handling from lexer
- Clean up whitespace in compile_and_run function
- Update documentation for scope entity return types

### 🎨 Styling

- Format code for consistency and readability

### ⚙️ Miscellaneous Tasks

- Move print_node function to misc
- Update Zig version to 0.14.0 and adjust build configurations
- Format parser
- Enable incremental builds in CI workflow and update build configuration
- Create a single consolidated test module to cover all modules
- Add comprehensive changelog documenting features, bug fixes, refactors, and enhancements
- *(docs)* Update changelog
