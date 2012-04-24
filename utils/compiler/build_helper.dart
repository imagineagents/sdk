// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#import('dart:io');
#import('dart:uri');

#import('../../lib/compiler/implementation/util/uri_extras.dart');
#import('../../lib/compiler/implementation/filenames.dart');

main() {
  List<String> arguments = new Options().arguments;
  Uri cwd = getCurrentDirectory();
  String productDir = appendSlash(nativeToUriPath(arguments[0]));
  String dartVmPath = nativeToUriPath(arguments[1]);
  String productionName = nativeToUriPath(arguments[2]);
  String developerName = nativeToUriPath(arguments[3]);
  String dartDir = appendSlash(nativeToUriPath(arguments[4]));

  Uri dartUri = cwd.resolve(dartDir);
  Uri productUri = cwd.resolve(productDir);

  Uri dartVmUri = productUri.resolve(dartVmPath);
  Uri productionUri = productUri.resolve(arguments[2]);
  Uri developerUri = productUri.resolve(arguments[3]);
  String productionScript = buildScript(dartUri, dartVmUri, '');
  String developerScript = buildScript(dartUri, dartVmUri,
                                       ' --enable_checked_mode');

  writeScript(productionUri, productionScript);
  writeScript(developerUri, developerScript);
}

writeScript(Uri uri, String script) {
  var f = new File(uriPathToNative(uri.path));
  var stream = f.openSync(FileMode.WRITE);
  try {
    stream.writeStringSync(script);
  } finally {
    stream.closeSync();
  }

  // TODO(ahe): Also make a .bat file for Windows.

  if (Platform.operatingSystem() != 'windows') {
    onExit(int exitCode, String stdout, String stderr) {
      if (exitCode != 0) {
        print(stdout);
        print(stderr);
        exit(exitCode);
      }
    }
    new Process.run('/bin/chmod', ['+x', uri.path], null, onExit);
  }
}

buildScript(Uri dartUri, Uri dartVmLocation, String options) {
  Uri dart2jsUri = dartUri.resolve('lib/compiler/implementation/dart2js.dart');
  String dart2jsPath = relativize(dartVmLocation, dart2jsUri);
  String libraryRoot = relativize(dartVmLocation, dartUri);
  libraryRoot = uriPathToNative('/../$libraryRoot');

  print('dartUri = $dartUri');
  print('dartVmLocation = $dartVmLocation');
  print('dart2jsUri = $dart2jsUri');
  print('dart2jsPath = $dart2jsPath');
  print('libraryRoot = $libraryRoot');

  return """
#!${dartVmLocation.path}$options
// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#import('dart:io');

#import('$dart2jsPath');

void main() {
  try {
    String libraryRoot = @'$libraryRoot';
    String script = new Options().script;
    List<String> argv = ['--library-root=\$script\$libraryRoot'];
    argv.addAll(new Options().arguments);
    compile(argv);
  } catch (var exception, var trace) {
    try {
      print('Internal error: \$exception');
    } catch (var ignored) {
      print('Internal error: error while printing exception');
    }
    try {
      print(trace);
    } finally {
      exit(253); // 253 is recognized as a crash by our test scripts.
    }
  }
}
""";
}
