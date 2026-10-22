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
  {
    title: "Fizz Buzz",
    code: `use std.io;

fun main() {
  num i = 1;
  for i <= 20 {
    if i % 15 == 0 {
      println("FizzBuzz");
    } elif i % 3 == 0 {
      println("Fizz");
    } elif i % 5 == 0 {
      println("Buzz");
    } else {
      println_fmt("{num}", i);
    }
    i = i + 1;
  }
}
`,
  },
  {
    title: "Enums + Fit",
    code: `use std.io;

enum Shape {
  Circle(num),
  Rectangle(num, num),
}

fun area(Shape s) num {
  fit s {
    Shape.Circle(r) -> { ret r * r * 3; }
    Shape.Rectangle(w, h) -> { ret w * h; }
  }
  ret 0;
}

fun main() {
  Shape c = Shape.Circle(4);
  Shape r = Shape.Rectangle(3, 5);
  println_fmt("circle area={num}", area(c));
  println_fmt("rectangle area={num}", area(r));
}
`,
  },
  {
    title: "Error Handling",
    code: `use std.io;
use std.result;

fun divide(num a, num b) Result<num, str> {
  if b == 0 {
    ret .Err("division by zero");
  }
  ret .Ok(a / b);
}

fun compute(num a, num b) Result<num, str> {
  num half = divide(a, b)!;
  ret .Ok(half + 1);
}

fun main() {
  fit compute(10, 2) {
    .Ok(v) -> { println_fmt("ok={num}", v); }
    .Err(e) -> { println_fmt("err={str}", e); }
  }
  fit compute(10, 0) {
    .Ok(v) -> { println_fmt("ok={num}", v); }
    .Err(e) -> { println_fmt("err={str}", e); }
  }
}
`,
  },
];
