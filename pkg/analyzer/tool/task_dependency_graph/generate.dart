// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * This file contains code to output a description of tasks and their
 * dependencies in ".dot" format.  Prior to running, the user should run "pub
 * get" in the analyzer directory to ensure that a "packages" folder exists.
 *
 * TODO(paulberry):
 * - Add general.dart and html.dart for completeness.
 * - Use Graphviz's "record" feature to produce more compact output
 *   (http://www.graphviz.org/content/node-shapes#record)
 * - Produce a warning if a result descriptor is found which isn't the output
 *   of exactly one task.
 * - Convert this tool to use package_config to find the package map.
 */
library analyzer.tool.task_dependency_graph.generate;

import 'dart:async';
import 'dart:io' hide File;
import 'dart:io' as io;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/package_map_resolver.dart';
import 'package:analyzer/src/context/builder.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/sdk/sdk.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:front_end/src/api_prototype/byte_store.dart';
import 'package:front_end/src/base/performance_logger.dart';
import 'package:front_end/src/codegen/tools.dart';
import 'package:front_end/src/testing/package_root.dart' as package_root;
import 'package:path/path.dart' as path;
import 'package:path/path.dart';

/**
 * Generate the target .dot file.
 */
main() async {
  String pkgPath = normalize(join(package_root.packageRoot, 'analyzer'));
  await GeneratedContent
      .generateAll(pkgPath, <GeneratedContent>[target, htmlTarget]);
}

final GeneratedFile htmlTarget = new GeneratedFile(
    'doc/tasks.html', (String pkgPath) => new Driver(pkgPath).generateHtml());

final GeneratedFile target = new GeneratedFile(
    'tool/task_dependency_graph/tasks.dot',
    (String pkgPath) => new Driver(pkgPath).generateFileContents());

typedef void GetterFinderCallback(PropertyAccessorElement element);

class Driver {
  static bool hasInitializedPlugins = false;
  PhysicalResourceProvider resourceProvider;
  AnalysisDriver driver;
  InterfaceType resultDescriptorType;
  InterfaceType listOfResultDescriptorType;
  ClassElement enginePluginClass;
  CompilationUnitElement taskUnitElement;
  InterfaceType extensionPointIdType;

  final String rootDir;

  Driver(String pkgPath) : rootDir = new Directory(pkgPath).absolute.path;

  /**
   * Get an [io.File] object corresponding to the file in which the generated
   * graph should be output.
   */
  io.File get file => new io.File(
      path.join(rootDir, 'tool', 'task_dependency_graph', 'tasks.dot'));

  /**
   * Starting at [node], find all calls to registerExtension() which refer to
   * the given [extensionIdVariable], and execute [callback] for the associated
   * result descriptors.
   */
  void findExtensions(AstNode node, TopLevelVariableElement extensionIdVariable,
      void callback(String descriptorName)) {
    Set<PropertyAccessorElement> resultDescriptors =
        new Set<PropertyAccessorElement>();
    node.accept(new ExtensionFinder(
        resultDescriptorType, extensionIdVariable, resultDescriptors.add));
    for (PropertyAccessorElement resultDescriptor in resultDescriptors) {
      callback(resultDescriptor.name);
    }
  }

  /**
   * Starting at [node], find all references to a getter of type
   * `List<ResultDescriptor>`, and execute [callback] on the getter names.
   */
  void findResultDescriptorLists(
      AstNode node, void callback(String descriptorListName)) {
    Set<PropertyAccessorElement> resultDescriptorLists =
        new Set<PropertyAccessorElement>();
    node.accept(new GetterFinder(
        listOfResultDescriptorType, resultDescriptorLists.add));
    for (PropertyAccessorElement resultDescriptorList
        in resultDescriptorLists) {
      // We only care about result descriptor lists associated with getters in
      // the engine plugin class.
      if (resultDescriptorList.enclosingElement != enginePluginClass) {
        continue;
      }
      callback(resultDescriptorList.name);
    }
  }

  void findResultDescriptors(
      AstNode node, void callback(String descriptorName)) {
    Set<PropertyAccessorElement> resultDescriptors =
        new Set<PropertyAccessorElement>();
    node.accept(new GetterFinder(resultDescriptorType, resultDescriptors.add));
    for (PropertyAccessorElement resultDescriptor in resultDescriptors) {
      callback(resultDescriptor.name);
    }
  }

  /**
   * Generate the task dependency graph and return it as a [String].
   */
  Future<String> generateFileContents() async {
    String data = await generateGraphData();
    return '''
// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// This file has been automatically generated.  Please do not edit it manually.
// To regenerate the file, use the script
// "pkg/analyzer/tool/task_dependency_graph/generate.dart".
//
// To render this graph using Graphviz (www.graphviz.org) use the command:
// "dot tasks.dot -Tpdf -O".
digraph G {
$data
}
''';
  }

  Future<String> generateGraphData() async {
    if (!hasInitializedPlugins) {
      AnalysisEngine.instance.processRequiredPlugins();
      hasInitializedPlugins = true;
    }
    List<String> lines = <String>[];
    resourceProvider = PhysicalResourceProvider.INSTANCE;
    DartSdk sdk = new FolderBasedDartSdk(resourceProvider,
        FolderBasedDartSdk.defaultSdkDirectory(resourceProvider));

    ContextBuilderOptions builderOptions = new ContextBuilderOptions();
    if (Platform.packageRoot != null) {
      builderOptions.defaultPackagesDirectoryPath =
          Uri.parse(Platform.packageRoot).toFilePath();
    } else if (Platform.packageConfig != null) {
      builderOptions.defaultPackageFilePath =
          Uri.parse(Platform.packageConfig).toFilePath();
    } else {
      // Let the context builder use the default algorithm for package
      // resolution.
    }

    ContextBuilder builder = new ContextBuilder(resourceProvider, null, null,
        options: builderOptions);
    List<UriResolver> uriResolvers = [
      new DartUriResolver(sdk),
      new PackageMapUriResolver(resourceProvider,
          builder.convertPackagesToMap(builder.createPackageMap(''))),
      new ResourceUriResolver(resourceProvider)
    ];

    var logger = new PerformanceLog(null);
    var scheduler = new AnalysisDriverScheduler(logger);
    driver = new AnalysisDriver(
        scheduler,
        logger,
        resourceProvider,
        new MemoryByteStore(),
        new FileContentOverlay(),
        null,
        new SourceFactory(uriResolvers),
        new AnalysisOptionsImpl());
    scheduler.start();

    TypeProvider typeProvider = await driver.currentSession.typeProvider;

    String dartDartPath = path.join(rootDir, 'lib', 'src', 'task', 'dart.dart');
    String taskPath = path.join(rootDir, 'lib', 'plugin', 'task.dart');
    String modelPath = path.join(rootDir, 'lib', 'task', 'model.dart');
    String enginePluginPath =
        path.join(rootDir, 'lib', 'src', 'plugin', 'engine_plugin.dart');

    CompilationUnitElement modelElement = await getUnitElement(modelPath);
    InterfaceType analysisTaskType = modelElement.getType('AnalysisTask').type;
    DartType dynamicType = typeProvider.dynamicType;
    resultDescriptorType = modelElement
        .getType('ResultDescriptor')
        .type
        .instantiate([dynamicType]);
    listOfResultDescriptorType =
        typeProvider.listType.instantiate([resultDescriptorType]);
    CompilationUnit enginePluginUnit = await getUnit(enginePluginPath);
    enginePluginClass = enginePluginUnit.element.getType('EnginePlugin');
    extensionPointIdType =
        enginePluginUnit.element.getType('ExtensionPointId').type;
    CompilationUnit dartDartUnit = await getUnit(dartDartPath);
    CompilationUnit taskUnit = await getUnit(taskPath);
    taskUnitElement = taskUnit.element;
    Set<String> results = new Set<String>();
    Set<String> resultLists = new Set<String>();
    for (CompilationUnitMember dartUnitMember in dartDartUnit.declarations) {
      if (dartUnitMember is ClassDeclaration) {
        ClassDeclaration clazz = dartUnitMember;
        if (!clazz.isAbstract &&
            clazz.element.type.isSubtypeOf(analysisTaskType)) {
          String task = clazz.name.name;

          MethodDeclaration buildInputsAst;
          VariableDeclaration descriptorField;
          for (ClassMember classMember in clazz.members) {
            if (classMember is MethodDeclaration &&
                classMember.name.name == 'buildInputs') {
              buildInputsAst = classMember;
            }
            if (classMember is FieldDeclaration) {
              for (VariableDeclaration field in classMember.fields.variables) {
                if (field.name.name == 'DESCRIPTOR') {
                  descriptorField = field;
                }
              }
            }
          }

          findResultDescriptors(buildInputsAst, (String input) {
            results.add(input);
            lines.add('  $input -> $task');
          });
          findResultDescriptorLists(buildInputsAst, (String input) {
            resultLists.add(input);
            lines.add('  $input -> $task');
          });
          findResultDescriptors(descriptorField, (String out) {
            results.add(out);
            lines.add('  $task -> $out');
          });
        }
      }
    }
    for (String resultList in resultLists) {
      lines.add('  $resultList [shape=hexagon]');
      TopLevelVariableElement extensionIdVariable = _getExtensionId(resultList);
      findExtensions(enginePluginUnit, extensionIdVariable, (String extension) {
        results.add(extension);
        lines.add('  $extension -> $resultList');
      });
    }
    for (String result in results) {
      lines.add('  $result [shape=box]');
    }
    lines.sort();
    return lines.join('\n');
  }

  Future<String> generateHtml() async {
    var data = await generateGraphData();
    return '''
<!DOCTYPE html>
<html>
<head>
    <title>Analysis Task Dependency Graph</title>
    <link rel="stylesheet" href="support/style.css">
    <script src="support/viz.js"></script>
    <script type="application/dart" src="support/web_app.dart.js"></script>
    <script src="support/dart.js"></script>
</head>
<body>
<button id="zoomBtn">Zoom</button>
<script type="text/vnd.graphviz" id="dot">
digraph G {
  tooltip="Analysis Task Dependency Graph";
  node [fontname=Helvetica];
  edge [fontname=Helvetica, fontcolor=gray];
$data
}
</script>
</body>
</html>
''';
  }

  Future<CompilationUnit> getUnit(String path) async {
    var result = await driver.getResult(path);
    return result.unit;
  }

  Future<CompilationUnitElement> getUnitElement(String path) async {
    UnitElementResult result = await driver.getUnitElement(path);
    return result.element;
  }

  /**
   * Find the result list getter having name [resultListGetterName] in the
   * [EnginePlugin] class, and use the [ExtensionPointId] annotation on that
   * getter to find the associated [TopLevelVariableElement] which can be used
   * to register extensions for that getter.
   */
  TopLevelVariableElement _getExtensionId(String resultListGetterName) {
    PropertyAccessorElement getter =
        enginePluginClass.getGetter(resultListGetterName);
    for (ElementAnnotation annotation in getter.metadata) {
      DartObjectImpl annotationValue = annotation.constantValue;
      if (annotationValue.type.isSubtypeOf(extensionPointIdType)) {
        String extensionPointId =
            annotationValue.fields['extensionPointId'].toStringValue();
        for (TopLevelVariableElement variable
            in taskUnitElement.topLevelVariables) {
          if (variable.name == extensionPointId) {
            return variable;
          }
        }
      }
    }
    throw new Exception(
        'Could not find extension ID corresponding to $resultListGetterName');
  }
}

/**
 * Visitor that finds calls that register extension points.  Specifically, we
 * look for calls of the form `method(extensionIdVariable, resultDescriptor)`,
 * where `resultDescriptor` has type [resultDescriptorType], and we pass the
 * corresponding result descriptor names to [callback].
 */
class ExtensionFinder extends GeneralizingAstVisitor {
  final InterfaceType resultDescriptorType;
  final TopLevelVariableElement extensionIdVariable;
  final GetterFinderCallback callback;

  ExtensionFinder(
      this.resultDescriptorType, this.extensionIdVariable, this.callback);

  @override
  visitIdentifier(Identifier node) {
    Element element = node.staticElement;
    if (element is PropertyAccessorElement &&
        element.isGetter &&
        element.variable == extensionIdVariable) {
      AstNode parent = node.parent;
      if (parent is ArgumentList &&
          parent.arguments.length == 2 &&
          parent.arguments[0] == node) {
        Expression extension = parent.arguments[1];
        if (extension is Identifier) {
          Element element = extension.staticElement;
          if (element is PropertyAccessorElement &&
              element.isGetter &&
              element.returnType.isSubtypeOf(resultDescriptorType)) {
            callback(element);
            return;
          }
        }
      }
      throw new Exception('Could not decode extension setup: $parent');
    }
  }
}

/**
 * Visitor that finds references to getters having a specific type (or a
 * subtype of that type)
 */
class GetterFinder extends GeneralizingAstVisitor {
  final InterfaceType type;
  final GetterFinderCallback callback;

  GetterFinder(this.type, this.callback);

  @override
  visitIdentifier(Identifier node) {
    Element element = node.staticElement;
    if (element is PropertyAccessorElement &&
        element.isGetter &&
        element.returnType.isSubtypeOf(type)) {
      callback(element);
    }
  }
}
