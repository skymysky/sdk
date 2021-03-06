// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.compiler_base;

import 'dart:async' show Future;

import 'package:front_end/src/fasta/scanner.dart' show StringToken;

import '../compiler_new.dart' as api;
import 'backend_strategy.dart';
import 'common/names.dart' show Selectors;
import 'common/names.dart' show Uris;
import 'common/tasks.dart' show CompilerTask, GenericTask, Measurer;
import 'common/work.dart' show WorkItem;
import 'common.dart';
import 'compile_time_constants.dart';
import 'common_elements.dart' show ElementEnvironment;
import 'deferred_load.dart' show DeferredLoadTask, OutputUnitData;
import 'diagnostics/code_location.dart';
import 'diagnostics/diagnostic_listener.dart' show DiagnosticReporter;
import 'diagnostics/messages.dart' show Message, MessageTemplate;
import 'dump_info.dart' show DumpInfoTask;
import 'elements/entities.dart';
import 'enqueue.dart' show Enqueuer, EnqueueTask, ResolutionEnqueuer;
import 'environment.dart';
import 'frontend_strategy.dart';
import 'inferrer/typemasks/masks.dart' show TypeMaskStrategy;
import 'io/source_information.dart' show SourceInformation;
import 'js_backend/backend.dart' show JavaScriptBackend;
import 'js_backend/inferred_data.dart';
import 'kernel/kernel_backend_strategy.dart';
import 'kernel/kernel_strategy.dart';
import 'library_loader.dart' show LibraryLoaderTask, LoadedLibraries;
import 'null_compiler_output.dart' show NullCompilerOutput, NullSink;
import 'options.dart' show CompilerOptions, DiagnosticOptions;
import 'ssa/nodes.dart' show HInstruction;
import 'types/abstract_value_domain.dart' show AbstractValueStrategy;
import 'types/types.dart'
    show GlobalTypeInferenceResults, GlobalTypeInferenceTask;
import 'universe/selector.dart' show Selector;
import 'universe/world_builder.dart'
    show ResolutionWorldBuilder, CodegenWorldBuilder;
import 'universe/world_impact.dart'
    show ImpactStrategy, WorldImpact, WorldImpactBuilderImpl;
import 'world.dart' show JClosedWorld, KClosedWorld;

typedef CompilerDiagnosticReporter MakeReporterFunction(
    Compiler compiler, CompilerOptions options);

abstract class Compiler {
  Measurer get measurer;

  api.CompilerInput get provider;

  FrontendStrategy frontendStrategy;
  BackendStrategy backendStrategy;
  CompilerDiagnosticReporter _reporter;
  Map<Entity, WorldImpact> _impactCache;
  ImpactCacheDeleter _impactCacheDeleter;

  ImpactStrategy impactStrategy = const ImpactStrategy();

  /// Options provided from command-line arguments.
  final CompilerOptions options;

  /**
   * If true, stop compilation after type inference is complete. Used for
   * debugging and testing purposes only.
   */
  bool stopAfterTypeInference = false;

  /// Output provider from user of Compiler API.
  api.CompilerOutput _outputProvider;

  api.CompilerOutput get outputProvider => _outputProvider;

  Uri _mainLibraryUri;

  JClosedWorld backendClosedWorldForTesting;

  DiagnosticReporter get reporter => _reporter;
  Map<Entity, WorldImpact> get impactCache => _impactCache;
  ImpactCacheDeleter get impactCacheDeleter => _impactCacheDeleter;

  // TODO(zarah): Remove this map and incorporate compile-time errors
  // in the model.
  /// Tracks elements with compile-time errors.
  final Map<Entity, List<DiagnosticMessage>> elementsWithCompileTimeErrors =
      new Map<Entity, List<DiagnosticMessage>>();

  final Environment environment;
  // TODO(sigmund): delete once we migrate the rest of the compiler to use
  // `environment` directly.
  @deprecated
  fromEnvironment(String name) => environment.valueOf(name);

  Entity get currentElement => _reporter.currentElement;

  List<CompilerTask> tasks;
  LibraryLoaderTask libraryLoader;
  GlobalTypeInferenceTask globalInference;
  JavaScriptBackend backend;
  CodegenWorldBuilder _codegenWorldBuilder;

  AbstractValueStrategy abstractValueStrategy = const TypeMaskStrategy();

  GenericTask selfTask;

  /// The constant environment for the frontend interpretation of compile-time
  /// constants.
  ConstantEnvironment constants;

  EnqueueTask enqueuer;
  DeferredLoadTask deferredLoadTask;
  DumpInfoTask dumpInfoTask;

  bool get hasCrashed => _reporter.hasCrashed;

  Progress progress = const Progress();

  static const int PHASE_SCANNING = 0;
  static const int PHASE_RESOLVING = 1;
  static const int PHASE_DONE_RESOLVING = 2;
  static const int PHASE_COMPILING = 3;
  int phase;

  bool compilationFailed = false;

  // Callback function used for testing resolution enqueuing.
  void Function() onResolutionQueueEmptyForTesting;

  // Callback function used for testing codegen enqueuing.
  void Function() onCodegenQueueEmptyForTesting;

  Compiler(
      {CompilerOptions options,
      api.CompilerOutput outputProvider,
      this.environment: const _EmptyEnvironment(),
      MakeReporterFunction makeReporter})
      : this.options = options {
    options.deriveOptions();
    options.validate();
    CompilerTask kernelFrontEndTask;
    selfTask = new GenericTask('self', measurer);
    _outputProvider = new _CompilerOutput(this, outputProvider);
    if (makeReporter != null) {
      _reporter = makeReporter(this, options);
    } else {
      _reporter = new CompilerDiagnosticReporter(this, options);
    }
    kernelFrontEndTask = new GenericTask('Front end', measurer);
    frontendStrategy = new KernelFrontEndStrategy(
        kernelFrontEndTask, options, reporter, environment);
    backendStrategy = new KernelBackendStrategy(this);
    _impactCache = <Entity, WorldImpact>{};
    _impactCacheDeleter = new _MapImpactCacheDeleter(_impactCache);

    if (options.verbose) {
      progress = new ProgressImpl(_reporter);
    }

    backend = createBackend();
    enqueuer = backend.makeEnqueuer();

    tasks = [
      libraryLoader =
          new LibraryLoaderTask(options, provider, reporter, measurer),
      kernelFrontEndTask,
      globalInference = new GlobalTypeInferenceTask(this),
      constants = backend.constantCompilerTask,
      deferredLoadTask = frontendStrategy.createDeferredLoadTask(this),
      // [enqueuer] is created earlier because it contains the resolution world
      // objects needed by other tasks.
      enqueuer,
      dumpInfoTask = new DumpInfoTask(this),
      selfTask,
    ];

    tasks.addAll(backend.tasks);
  }

  /// Creates the backend.
  ///
  /// Override this to mock the backend for testing.
  JavaScriptBackend createBackend() {
    return new JavaScriptBackend(this,
        generateSourceMap: options.generateSourceMap,
        useStartupEmitter: options.useStartupEmitter,
        useMultiSourceInfo: options.useMultiSourceInfo,
        useNewSourceInfo: options.useNewSourceInfo);
  }

  ResolutionWorldBuilder get resolutionWorldBuilder =>
      enqueuer.resolution.worldBuilder;

  CodegenWorldBuilder get codegenWorldBuilder {
    assert(
        _codegenWorldBuilder != null,
        failedAt(NO_LOCATION_SPANNABLE,
            "CodegenWorldBuilder has not been created yet."));
    return _codegenWorldBuilder;
  }

  bool get disableTypeInference =>
      options.disableTypeInference || compilationFailed;

  // Compiles the dart script at [uri].
  //
  // The resulting future will complete with true if the compilation
  // succeeded.
  Future<bool> run(Uri uri) => selfTask.measureSubtask("Compiler.run", () {
        measurer.startWallClock();

        return new Future.sync(() => runInternal(uri))
            .catchError((error) => _reporter.onError(uri, error))
            .whenComplete(() {
          measurer.stopWallClock();
        }).then((_) {
          return !compilationFailed;
        });
      });

  /// This method is called when all new libraries loaded through
  /// [LibraryLoader.loadLibrary] has been loaded and their imports/exports
  /// have been computed.
  ///
  /// [loadedLibraries] contains the newly loaded libraries.
  ///
  /// The method returns a [Future] allowing for the loading of additional
  /// libraries.
  LoadedLibraries processLoadedLibraries(LoadedLibraries loadedLibraries) {
    frontendStrategy.registerLoadedLibraries(loadedLibraries);
    loadedLibraries.forEachLibrary((Uri uri) {
      LibraryEntity library =
          frontendStrategy.elementEnvironment.lookupLibrary(uri);
      backend.setAnnotations(library);
    });

    // TODO(efortuna, sigmund): These validation steps should be done in the
    // front end for the Kernel path since Kernel doesn't have the notion of
    // imports (everything has already been resolved). (See
    // https://github.com/dart-lang/sdk/issues/29368)
    if (loadedLibraries.containsLibrary(Uris.dart_mirrors)) {
      reporter.reportWarningMessage(NO_LOCATION_SPANNABLE,
          MessageKind.MIRRORS_LIBRARY_NOT_SUPPORT_WITH_CFE);
    }
    backend.onLibrariesLoaded(frontendStrategy.commonElements, loadedLibraries);
    return loadedLibraries;
  }

  Future runInternal(Uri uri) async {
    // TODO(ahe): This prevents memory leaks when invoking the compiler
    // multiple times. Implement a better mechanism where we can store
    // such caches in the compiler and get access to them through a
    // suitably maintained static reference to the current compiler.
    StringToken.canonicalizer.clear();
    Selector.canonicalizedValues.clear();

    // The selector objects held in static fields must remain canonical.
    for (Selector selector in Selectors.ALL) {
      Selector.canonicalizedValues
          .putIfAbsent(selector.hashCode, () => <Selector>[])
          .add(selector);
    }

    assert(uri != null);
    // As far as I can tell, this branch is only used by test code.
    reporter.log('Compiling $uri (${options.buildId})');
    LoadedLibraries loadedLibraries = await libraryLoader.loadLibraries(uri);
    // Note: libraries may be null because of errors trying to find files or
    // parse-time errors (when using `package:front_end` as a loader).
    if (loadedLibraries == null) return;
    _mainLibraryUri = loadedLibraries.rootLibraryUri;
    processLoadedLibraries(loadedLibraries);
    compileLoadedLibraries(loadedLibraries);
  }

  /// Starts the resolution phase, creating the [ResolutionEnqueuer] if not
  /// already created.
  ///
  /// During normal compilation resolution only started once, but through
  /// [analyzeUri] resolution is started repeatedly.
  ResolutionEnqueuer startResolution() {
    ResolutionEnqueuer resolutionEnqueuer;
    if (enqueuer.hasResolution) {
      resolutionEnqueuer = enqueuer.resolution;
    } else {
      resolutionEnqueuer = enqueuer.createResolutionEnqueuer();
      backend.onResolutionStart();
    }
    return resolutionEnqueuer;
  }

  JClosedWorld computeClosedWorld(LoadedLibraries loadedLibraries) {
    ResolutionEnqueuer resolutionEnqueuer = startResolution();
    WorldImpactBuilderImpl mainImpact = new WorldImpactBuilderImpl();
    FunctionEntity mainFunction = frontendStrategy.computeMain(mainImpact);

    // In order to see if a library is deferred, we must compute the
    // compile-time constants that are metadata.  This means adding
    // something to the resolution queue.  So we cannot wait with
    // this until after the resolution queue is processed.
    deferredLoadTask.beforeResolution(loadedLibraries);
    impactStrategy = backend.createImpactStrategy(
        supportDeferredLoad: deferredLoadTask.isProgramSplit,
        supportDumpInfo: options.dumpInfo);

    phase = PHASE_RESOLVING;
    resolutionEnqueuer.applyImpact(mainImpact);
    reporter.log('Resolving...');

    processQueue(frontendStrategy.elementEnvironment, resolutionEnqueuer,
        mainFunction, loadedLibraries.libraries,
        onProgress: showResolutionProgress);
    backend.onResolutionEnd();
    resolutionEnqueuer.logSummary(reporter.log);

    _reporter.reportSuppressedMessagesSummary();

    if (compilationFailed) {
      if (!options.generateCodeWithCompileTimeErrors) {
        return null;
      }
      if (mainFunction == null) return null;
      if (!backend.enableCodegenWithErrorsIfSupported(NO_LOCATION_SPANNABLE)) {
        return null;
      }
    }

    assert(mainFunction != null);

    JClosedWorld closedWorld = closeResolution(mainFunction);
    backendClosedWorldForTesting = closedWorld;
    return closedWorld;
  }

  GlobalTypeInferenceResults performGlobalTypeInference(
      JClosedWorld closedWorld) {
    FunctionEntity mainFunction = closedWorld.elementEnvironment.mainFunction;
    reporter.log('Inferring types...');
    InferredDataBuilder inferredDataBuilder = new InferredDataBuilderImpl();
    backend.processAnnotations(closedWorld, inferredDataBuilder);
    return globalInference.runGlobalTypeInference(
        mainFunction, closedWorld, inferredDataBuilder);
  }

  Enqueuer generateJavaScriptCode(
      LoadedLibraries loadedLibraries,
      JClosedWorld closedWorld,
      GlobalTypeInferenceResults globalInferenceResults) {
    FunctionEntity mainFunction = closedWorld.elementEnvironment.mainFunction;
    reporter.log('Compiling...');
    phase = PHASE_COMPILING;

    Enqueuer codegenEnqueuer =
        startCodegen(closedWorld, globalInferenceResults);
    processQueue(closedWorld.elementEnvironment, codegenEnqueuer, mainFunction,
        loadedLibraries.libraries,
        onProgress: showCodegenProgress);
    codegenEnqueuer.logSummary(reporter.log);

    int programSize = backend.assembleProgram(
        closedWorld, globalInferenceResults.inferredData);

    if (options.dumpInfo) {
      dumpInfoTask.reportSize(programSize);
      dumpInfoTask.dumpInfo(closedWorld, globalInferenceResults);
    }

    backend.onCodegenEnd();

    return codegenEnqueuer;
  }

  /// Performs the compilation when all libraries have been loaded.
  void compileLoadedLibraries(LoadedLibraries loadedLibraries) =>
      selfTask.measureSubtask("Compiler.compileLoadedLibraries", () {
        JClosedWorld closedWorld = computeClosedWorld(loadedLibraries);
        if (closedWorld != null) {
          GlobalTypeInferenceResults globalInferenceResults =
              performGlobalTypeInference(closedWorld);
          if (stopAfterTypeInference) return;
          Enqueuer codegenEnqueuer = generateJavaScriptCode(
              loadedLibraries, closedWorld, globalInferenceResults);
          checkQueues(enqueuer.resolution, codegenEnqueuer);
        }
      });

  Enqueuer startCodegen(JClosedWorld closedWorld,
      GlobalTypeInferenceResults globalInferenceResults) {
    Enqueuer codegenEnqueuer =
        enqueuer.createCodegenEnqueuer(closedWorld, globalInferenceResults);
    _codegenWorldBuilder = codegenEnqueuer.worldBuilder;
    codegenEnqueuer.applyImpact(backend.onCodegenStart(
        closedWorld, _codegenWorldBuilder, backendStrategy.sorter));
    return codegenEnqueuer;
  }

  /// Perform the steps needed to fully end the resolution phase.
  JClosedWorld closeResolution(FunctionEntity mainFunction) {
    phase = PHASE_DONE_RESOLVING;

    KClosedWorld closedWorld = resolutionWorldBuilder.closeWorld();
    OutputUnitData result = deferredLoadTask.run(mainFunction, closedWorld);
    JClosedWorld closedWorldRefiner =
        backendStrategy.createJClosedWorld(closedWorld);

    backend.onDeferredLoadComplete(result);

    return closedWorldRefiner;
  }

  /**
   * Empty the [enqueuer] queue.
   */
  void emptyQueue(Enqueuer enqueuer, {void onProgress(Enqueuer enqueuer)}) {
    selfTask.measureSubtask("Compiler.emptyQueue", () {
      enqueuer.forEach((WorkItem work) {
        if (onProgress != null) {
          onProgress(enqueuer);
        }
        reporter.withCurrentElement(
            work.element,
            () => selfTask.measureSubtask("world.applyImpact", () {
                  enqueuer.applyImpact(
                      selfTask.measureSubtask("work.run", () => work.run()),
                      impactSource: work.element);
                }));
      });
    });
  }

  void processQueue(ElementEnvironment elementEnvironment, Enqueuer enqueuer,
      FunctionEntity mainMethod, Iterable<Uri> libraries,
      {void onProgress(Enqueuer enqueuer)}) {
    selfTask.measureSubtask("Compiler.processQueue", () {
      enqueuer.open(impactStrategy, mainMethod, libraries);
      progress.startPhase();
      emptyQueue(enqueuer, onProgress: onProgress);
      enqueuer.queueIsClosed = true;
      enqueuer.close();
      // Notify the impact strategy impacts are no longer needed for this
      // enqueuer.
      impactStrategy.onImpactUsed(enqueuer.impactUse);
      assert(compilationFailed ||
          enqueuer.checkNoEnqueuedInvokedInstanceMethods(elementEnvironment));
    });
  }

  /**
   * Perform various checks of the queues. This includes checking that
   * the queues are empty (nothing was added after we stopped
   * processing the queues). Also compute the number of methods that
   * were resolved, but not compiled (aka excess resolution).
   */
  checkQueues(Enqueuer resolutionEnqueuer, Enqueuer codegenEnqueuer) {
    for (Enqueuer enqueuer in [resolutionEnqueuer, codegenEnqueuer]) {
      enqueuer.checkQueueIsEmpty();
    }
  }

  void showResolutionProgress(Enqueuer enqueuer) {
    assert(phase == PHASE_RESOLVING, 'Unexpected phase: $phase');
    progress.showProgress(
        'Resolved ', enqueuer.processedEntities.length, ' elements.');
  }

  void showCodegenProgress(Enqueuer enqueuer) {
    progress.showProgress(
        'Compiled ', enqueuer.processedEntities.length, ' methods.');
  }

  void reportDiagnostic(DiagnosticMessage message,
      List<DiagnosticMessage> infos, api.Diagnostic kind);

  void reportCrashInUserCode(String message, exception, stackTrace) {
    reporter.onCrashInUserCode(message, exception, stackTrace);
  }

  /// Messages for which compile-time errors are reported but compilation
  /// continues regardless.
  static const List<MessageKind> BENIGN_ERRORS = const <MessageKind>[
    MessageKind.INVALID_METADATA,
    MessageKind.INVALID_METADATA_GENERIC,
  ];

  bool markCompilationAsFailed(DiagnosticMessage message, api.Diagnostic kind) {
    if (options.testMode) {
      // When in test mode, i.e. on the build-bot, we always stop compilation.
      return true;
    }
    if (reporter.options.fatalWarnings) {
      return true;
    }
    return !BENIGN_ERRORS.contains(message.message.kind);
  }

  void fatalDiagnosticReported(DiagnosticMessage message,
      List<DiagnosticMessage> infos, api.Diagnostic kind) {
    if (markCompilationAsFailed(message, kind)) {
      compilationFailed = true;
    }
    registerCompileTimeError(currentElement, message);
  }

  /// Helper for determining whether the current element is declared within
  /// 'user code'.
  ///
  /// See [inUserCode] for what defines 'user code'.
  bool currentlyInUserCode() {
    return inUserCode(currentElement);
  }

  /// Helper for determining whether [element] is declared within 'user code'.
  ///
  /// What constitutes 'user code' is defined by the URI(s) provided by the
  /// entry point(s) of compilation or analysis:
  ///
  /// If an entrypoint URI uses the 'package' scheme then every library from
  /// that same package is considered to be in user code. For instance, if
  /// an entry point URI is 'package:foo/bar.dart' then every library whose
  /// canonical URI starts with 'package:foo/' is in user code.
  ///
  /// If an entrypoint URI uses another scheme than 'package' then every library
  /// with that scheme is in user code. For instance, an entry point URI is
  /// 'file:///foo.dart' then every library whose canonical URI scheme is
  /// 'file' is in user code.
  ///
  /// If [assumeInUserCode] is `true`, [element] is assumed to be in user code
  /// if no entrypoints have been set.
  bool inUserCode(Entity element, {bool assumeInUserCode: false}) {
    if (element == null) return assumeInUserCode;
    Uri libraryUri = _uriFromElement(element);
    if (libraryUri == null) return false;
    Iterable<CodeLocation> userCodeLocations =
        computeUserCodeLocations(assumeInUserCode: assumeInUserCode);
    return userCodeLocations.any(
        (CodeLocation codeLocation) => codeLocation.inSameLocation(libraryUri));
  }

  Iterable<CodeLocation> computeUserCodeLocations(
      {bool assumeInUserCode: false}) {
    List<CodeLocation> userCodeLocations = <CodeLocation>[];
    if (_mainLibraryUri != null) {
      userCodeLocations.add(new CodeLocation(_mainLibraryUri));
    }
    if (userCodeLocations.isEmpty && assumeInUserCode) {
      // Assume in user code since [mainApp] has not been set yet.
      userCodeLocations.add(const AnyLocation());
    }
    return userCodeLocations;
  }

  /// Return a canonical URI for the source of [element].
  ///
  /// For a package library with canonical URI 'package:foo/bar/baz.dart' the
  /// return URI is 'package:foo'. For non-package libraries the returned URI is
  /// the canonical URI of the library itself.
  Uri getCanonicalUri(Entity element) {
    Uri libraryUri = _uriFromElement(element);
    if (libraryUri == null) return null;
    if (libraryUri.scheme == 'package') {
      int slashPos = libraryUri.path.indexOf('/');
      if (slashPos != -1) {
        String packageName = libraryUri.path.substring(0, slashPos);
        return new Uri(scheme: 'package', path: packageName);
      }
    }
    return libraryUri;
  }

  Uri _uriFromElement(Entity element) {
    if (element is LibraryEntity) {
      return element.canonicalUri;
    } else if (element is ClassEntity) {
      return element.library.canonicalUri;
    } else if (element is MemberEntity) {
      return element.library.canonicalUri;
    }
    return null;
  }

  /// Returns [true] if a compile-time error has been reported for element.
  bool elementHasCompileTimeError(Entity element) {
    return elementsWithCompileTimeErrors.containsKey(element);
  }

  /// Associate [element] with a compile-time error [message].
  void registerCompileTimeError(Entity element, DiagnosticMessage message) {
    // The information is only needed if [generateCodeWithCompileTimeErrors].
    if (options.generateCodeWithCompileTimeErrors) {
      if (element == null) {
        // Record as global error.
        // TODO(zarah): Extend element model to represent compile-time
        // errors instead of using a map.
        element = frontendStrategy.elementEnvironment.mainFunction;
      }
      elementsWithCompileTimeErrors
          .putIfAbsent(element, () => <DiagnosticMessage>[])
          .add(message);
    }
  }
}

class _CompilerOutput implements api.CompilerOutput {
  final Compiler _compiler;
  final api.CompilerOutput _userOutput;

  _CompilerOutput(this._compiler, api.CompilerOutput output)
      : this._userOutput = output ?? const NullCompilerOutput();

  @override
  api.OutputSink createOutputSink(
      String name, String extension, api.OutputType type) {
    if (_compiler.compilationFailed) {
      if (!_compiler.options.generateCodeWithCompileTimeErrors ||
          _compiler.options.testMode) {
        // Disable output in test mode: The build bot currently uses the time
        // stamp of the generated file to determine whether the output is
        // up-to-date.
        return NullSink.outputProvider(name, extension, type);
      }
    }
    return _userOutput.createOutputSink(name, extension, type);
  }
}

/// Information about suppressed warnings and hints for a given library.
class SuppressionInfo {
  int warnings = 0;
  int hints = 0;
}

class CompilerDiagnosticReporter extends DiagnosticReporter {
  final Compiler compiler;
  final DiagnosticOptions options;

  Entity _currentElement;
  bool hasCrashed = false;

  /// `true` if the last diagnostic was filtered, in which case the
  /// accompanying info message should be filtered as well.
  bool lastDiagnosticWasFiltered = false;

  /// Map containing information about the warnings and hints that have been
  /// suppressed for each library.
  Map<Uri, SuppressionInfo> suppressedWarnings = <Uri, SuppressionInfo>{};

  CompilerDiagnosticReporter(this.compiler, this.options);

  Entity get currentElement => _currentElement;

  DiagnosticMessage createMessage(Spannable spannable, MessageKind messageKind,
      [Map arguments = const {}]) {
    SourceSpan span = spanFromSpannable(spannable);
    MessageTemplate template = MessageTemplate.TEMPLATES[messageKind];
    Message message = template.message(arguments, options.terseDiagnostics);
    return new DiagnosticMessage(span, spannable, message);
  }

  void reportError(DiagnosticMessage message,
      [List<DiagnosticMessage> infos = const <DiagnosticMessage>[]]) {
    reportDiagnosticInternal(message, infos, api.Diagnostic.ERROR);
  }

  void reportWarning(DiagnosticMessage message,
      [List<DiagnosticMessage> infos = const <DiagnosticMessage>[]]) {
    reportDiagnosticInternal(message, infos, api.Diagnostic.WARNING);
  }

  void reportHint(DiagnosticMessage message,
      [List<DiagnosticMessage> infos = const <DiagnosticMessage>[]]) {
    reportDiagnosticInternal(message, infos, api.Diagnostic.HINT);
  }

  @deprecated
  void reportInfo(Spannable node, MessageKind messageKind,
      [Map arguments = const {}]) {
    reportDiagnosticInternal(createMessage(node, messageKind, arguments),
        const <DiagnosticMessage>[], api.Diagnostic.INFO);
  }

  void reportDiagnosticInternal(DiagnosticMessage message,
      List<DiagnosticMessage> infos, api.Diagnostic kind) {
    if (!options.showAllPackageWarnings &&
        message.spannable != NO_LOCATION_SPANNABLE) {
      switch (kind) {
        case api.Diagnostic.WARNING:
        case api.Diagnostic.HINT:
          Entity element = elementFromSpannable(message.spannable);
          if (!compiler.inUserCode(element, assumeInUserCode: true)) {
            Uri uri = compiler.getCanonicalUri(element);
            if (options.showPackageWarningsFor(uri)) {
              reportDiagnostic(message, infos, kind);
              return;
            }
            SuppressionInfo info = suppressedWarnings.putIfAbsent(
                uri, () => new SuppressionInfo());
            if (kind == api.Diagnostic.WARNING) {
              info.warnings++;
            } else {
              info.hints++;
            }
            lastDiagnosticWasFiltered = true;
            return;
          }
          break;
        case api.Diagnostic.INFO:
          if (lastDiagnosticWasFiltered) {
            return;
          }
          break;
      }
    }
    lastDiagnosticWasFiltered = false;
    reportDiagnostic(message, infos, kind);
  }

  void reportDiagnostic(DiagnosticMessage message,
      List<DiagnosticMessage> infos, api.Diagnostic kind) {
    compiler.reportDiagnostic(message, infos, kind);
    if (kind == api.Diagnostic.ERROR ||
        kind == api.Diagnostic.CRASH ||
        (options.fatalWarnings && kind == api.Diagnostic.WARNING)) {
      Entity errorElement;
      if (message.spannable is Entity) {
        errorElement = message.spannable;
      } else {
        errorElement = currentElement;
      }
      compiler.registerCompileTimeError(errorElement, message);
      compiler.fatalDiagnosticReported(message, infos, kind);
    }
  }

  @override
  bool get hasReportedError => compiler.compilationFailed;

  /**
   * Perform an operation, [f], returning the return value from [f].  If an
   * error occurs then report it as having occurred during compilation of
   * [element].  Can be nested.
   */
  withCurrentElement(Entity element, f()) {
    Entity old = currentElement;
    _currentElement = element;
    try {
      return f();
    } on SpannableAssertionFailure catch (ex) {
      if (!hasCrashed) {
        reportAssertionFailure(ex);
        pleaseReportCrash();
      }
      hasCrashed = true;
      rethrow;
    } on StackOverflowError {
      // We cannot report anything useful in this case, because we
      // do not have enough stack space.
      rethrow;
    } catch (ex) {
      if (hasCrashed) rethrow;
      try {
        unhandledExceptionOnElement(element);
      } catch (doubleFault) {
        // Ignoring exceptions in exception handling.
      }
      rethrow;
    } finally {
      _currentElement = old;
    }
  }

  void reportAssertionFailure(SpannableAssertionFailure ex) {
    String message =
        (ex.message != null) ? tryToString(ex.message) : tryToString(ex);
    reportDiagnosticInternal(
        createMessage(ex.node, MessageKind.GENERIC, {'text': message}),
        const <DiagnosticMessage>[],
        api.Diagnostic.CRASH);
  }

  /// Using [frontendStrategy] to compute a [SourceSpan] from spannable using
  /// the [currentElement] as context.
  SourceSpan _spanFromStrategy(Spannable spannable) {
    SourceSpan span;
    if (compiler.phase == Compiler.PHASE_COMPILING) {
      span =
          compiler.backendStrategy.spanFromSpannable(spannable, currentElement);
    } else {
      span = compiler.frontendStrategy
          .spanFromSpannable(spannable, currentElement);
    }
    if (span != null) return span;
    throw 'No error location.';
  }

  SourceSpan spanFromSpannable(Spannable spannable) {
    if (spannable == CURRENT_ELEMENT_SPANNABLE) {
      spannable = currentElement;
    } else if (spannable == NO_LOCATION_SPANNABLE) {
      if (currentElement == null) return null;
      spannable = currentElement;
    }
    if (spannable is SourceSpan) {
      return spannable;
    } else if (spannable is HInstruction) {
      Entity element = spannable.sourceElement;
      if (element == null) element = currentElement;
      SourceInformation position = spannable.sourceInformation;
      if (position != null) return position.sourceSpan;
      return _spanFromStrategy(element);
    } else {
      return _spanFromStrategy(spannable);
    }
  }

  internalError(Spannable spannable, reason) {
    String message = tryToString(reason);
    reportDiagnosticInternal(
        createMessage(spannable, MessageKind.GENERIC, {'text': message}),
        const <DiagnosticMessage>[],
        api.Diagnostic.CRASH);
    throw 'Internal Error: $message';
  }

  void unhandledExceptionOnElement(Entity element) {
    if (hasCrashed) return;
    hasCrashed = true;
    reportDiagnostic(createMessage(element, MessageKind.COMPILER_CRASHED),
        const <DiagnosticMessage>[], api.Diagnostic.CRASH);
    pleaseReportCrash();
  }

  void pleaseReportCrash() {
    print(MessageTemplate.TEMPLATES[MessageKind.PLEASE_REPORT_THE_CRASH]
        .message({'buildId': compiler.options.buildId}));
  }

  /// Finds the approximate [Element] for [node]. [currentElement] is used as
  /// the default value.
  Entity elementFromSpannable(Spannable node) {
    Entity element;
    if (node is Entity) {
      element = node;
    } else if (node is HInstruction) {
      element = node.sourceElement;
    }
    return element != null ? element : currentElement;
  }

  void log(message) {
    Message msg = MessageTemplate.TEMPLATES[MessageKind.GENERIC]
        .message({'text': '$message'});
    reportDiagnostic(new DiagnosticMessage(null, null, msg),
        const <DiagnosticMessage>[], api.Diagnostic.VERBOSE_INFO);
  }

  String tryToString(object) {
    try {
      return object.toString();
    } catch (_) {
      return '<exception in toString()>';
    }
  }

  onError(Uri uri, error) {
    try {
      if (!hasCrashed) {
        hasCrashed = true;
        if (error is SpannableAssertionFailure) {
          reportAssertionFailure(error);
        } else {
          reportDiagnostic(
              createMessage(
                  new SourceSpan(uri, 0, 0), MessageKind.COMPILER_CRASHED),
              const <DiagnosticMessage>[],
              api.Diagnostic.CRASH);
        }
        pleaseReportCrash();
      }
    } catch (doubleFault) {
      // Ignoring exceptions in exception handling.
    }
    throw error;
  }

  @override
  void onCrashInUserCode(String message, exception, stackTrace) {
    hasCrashed = true;
    print('$message: ${tryToString(exception)}');
    print(tryToString(stackTrace));
  }

  void reportSuppressedMessagesSummary() {
    if (!options.showAllPackageWarnings && !options.suppressWarnings) {
      suppressedWarnings.forEach((Uri uri, SuppressionInfo info) {
        MessageKind kind = MessageKind.HIDDEN_WARNINGS_HINTS;
        if (info.warnings == 0) {
          kind = MessageKind.HIDDEN_HINTS;
        } else if (info.hints == 0) {
          kind = MessageKind.HIDDEN_WARNINGS;
        }
        MessageTemplate template = MessageTemplate.TEMPLATES[kind];
        Message message = template.message(
            {'warnings': info.warnings, 'hints': info.hints, 'uri': uri},
            options.terseDiagnostics);
        reportDiagnostic(new DiagnosticMessage(null, null, message),
            const <DiagnosticMessage>[], api.Diagnostic.HINT);
      });
    }
  }
}

class _MapImpactCacheDeleter implements ImpactCacheDeleter {
  final Map<Entity, WorldImpact> _impactCache;
  _MapImpactCacheDeleter(this._impactCache);

  bool retainCachesForTesting = false;

  void uncacheWorldImpact(Entity element) {
    if (retainCachesForTesting) return;
    _impactCache.remove(element);
  }

  void emptyCache() {
    if (retainCachesForTesting) return;
    _impactCache.clear();
  }
}

class _EmptyEnvironment implements Environment {
  const _EmptyEnvironment();

  String valueOf(String key) => null;
}

/// Interface for showing progress during compilation.
class Progress {
  const Progress();

  /// Starts a new phase for which to show progress.
  void startPhase() {}

  /// Shows progress of the current phase if needed. The shown message is
  /// computed as '$prefix$count$suffix'.
  void showProgress(String prefix, int count, String suffix) {}
}

/// Progress implementations that prints progress to the [DiagnosticReporter]
/// with 500ms intervals.
class ProgressImpl implements Progress {
  final DiagnosticReporter _reporter;
  final Stopwatch _stopwatch = new Stopwatch()..start();

  ProgressImpl(this._reporter);

  void showProgress(String prefix, int count, String suffix) {
    if (_stopwatch.elapsedMilliseconds > 500) {
      _reporter.log('$prefix$count$suffix');
      _stopwatch.reset();
    }
  }

  void startPhase() {
    _stopwatch.reset();
  }
}
