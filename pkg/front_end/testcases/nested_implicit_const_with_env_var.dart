// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*@testedFeatures=error*/

const int foo = const int.fromEnvironment("fisk");

class A {
  final int bar;
  const A(this.bar);
}

class B {
  final A baz;
  const B(this.baz);
}

class C {
  fun() {
    /*@error=CantDetermineConstness*/ B(
        /*@error=CantDetermineConstness*/ A(foo));
  }
}

main() {}
