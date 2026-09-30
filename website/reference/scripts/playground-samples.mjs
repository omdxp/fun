// The "Interactive Playground" tab's curated starter samples - fixed,
// known-at-build-time code (the same category as a docs example, not
// truly arbitrary user typing), so `prebake-wasm.mjs` also pre-bakes
// these. Shared here rather than duplicated so `generate-content.mjs`
// (which bundles them into content.json for the frontend to render) and
// `prebake-wasm.mjs` (which compiles them) can't drift apart.
export const samples = [
  {
    title: "Hello World",
    code: `use std.c.io;

fun main() {
  printf("hello from fun\\n");
}
`,
  },
  {
    title: "Alias Imports",
    code: `// file: main.fn
use std.io;
use mod1 as one;
use mod2 as two;

fun main() {
  num a = one.pick();
  num b = two.pick();
  println_fmt("a+b={num}", a + b);
}

// file: mod1.fn
pub fun pick() num {
  ret 10;
}

// file: mod2.fn
pub fun pick() num {
  ret 32;
}
`,
  },
  {
    title: "Compounds + Impl",
    code: `use std.io;

compound Point {
  num x;
  num y;
}

impl Point {
  move_by(num dx, num dy) {
    self.x = self.x + dx;
    self.y = self.y + dy;
  }
}

fun main() {
  Point p;
  p.x = 1; p.y = 2;
  p.move_by(3, 4);
  println_fmt("{num},{num}", p.x, p.y);
}
`,
  },
];
