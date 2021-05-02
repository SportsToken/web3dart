import 'dart:async';
import 'dart:convert';

import 'package:code_builder/code_builder.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart';
import 'package:web3dart/contracts.dart';

import 'utils.dart';

class ContractGenerator implements Builder {
  const ContractGenerator();

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.abi.json': ['.g.dart']
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    final withoutExtension =
        inputId.path.substring(0, inputId.path.length - '.abi.json'.length);

    var abiCode = await buildStep.readAsString(inputId);
    // Remove unnecessary whitespace
    abiCode = json.encode(json.decode(abiCode));
    final abi = ContractAbi.fromJson(abiCode, _suggestName(withoutExtension));

    final outputId = AssetId(inputId.package, '$withoutExtension.g.dart');
    await buildStep.writeAsString(outputId, _generateForAbi(abi, abiCode));
  }

  String _suggestName(String pathWithoutExtension) {
    final base = basename(pathWithoutExtension);
    return base[0].toUpperCase() + base.substring(1);
  }

  //main method that parses abi to dart code
  String _generateForAbi(ContractAbi abi, String abiCode) {
    final generation = _ContractGeneration(abi, abiCode);
    final library = generation.generate();

    final emitter = DartEmitter(
        allocator: Allocator.simplePrefixing(), useNullSafetySyntax: true);
    return DartFormatter().format('''
// Generated code, do not modify. Run `build_runner build` to re-generate!
// @dart=2.12
${library.accept(emitter)}
''');
  }
}

class _ContractGeneration {
  final ContractAbi _abi;
  final String _abiCode;

  final List<Spec> _additionalSpecs = [];
  final Map<ContractFunction, Reference> _functionToResultClass = {};

  // The `self` field, storing a reference to the deployed contract.
  static final self = refer('self');

  // The `client` field, storing a reference to the web3client instance.
  static final client = refer('client');

  _ContractGeneration(this._abi, this._abiCode);

  Library generate() {
    return Library((b) {
      b.body
        ..add(Class(_createContractClass))
        ..addAll(_additionalSpecs);
    });
  }

  void _createContractClass(ClassBuilder b) {
    b
      ..name = _abi.name
      ..extend = generatedContract
      ..constructors.add(Constructor(_createContractConstructor))
      ..methods.addAll([
        for (final function in _abi.functions)
          if (!function.isConstructor)
            Method((b) => _methodForFunction(function, b)),
        for (final event in _abi.events)
          Method((b) => _methodForEvent(event, b))
      ]);
  }

  void _createContractConstructor(ConstructorBuilder b) {
    b
      ..optionalParameters.addAll([
        Parameter((b) => b
          ..name = 'address'
          ..type = ethereumAddress
          ..named = true
          ..required = true),
        Parameter((b) => b
          ..name = 'client'
          ..type = web3Client
          ..named = true
          ..required = true),
        Parameter((b) => b
          ..name = 'chainId'
          ..type = dartInt.rebuild((b) => b.isNullable = true)
          ..required = false
          ..named = true),
      ])
      ..initializers.add(callSuper([
        deployedContract.newInstance([
          contractAbi.newInstanceNamed(
            'fromJson',
            [literalString(_abiCode), literalString(_abi.name)],
          ),
          refer('address'),
        ]),
        refer('client'),
        refer('chainId'),
      ]).code);
  }

  void _methodForFunction(ContractFunction fun, MethodBuilder b) {
    b
      ..modifier = MethodModifier.async
      ..returns = _returnType(fun)
      ..name = fun.name
      ..body = fun.isConstant ? _bodyForImmutable(fun) : _bodyForMutable(fun)
      ..requiredParameters.addAll(_parametersFor(fun));

    if (!fun.isConstant) {
      b.optionalParameters.add(Parameter((b) => b
        ..type = credentials
        ..name = 'credentials'
        ..named = true
        ..required = true));
    }
  }

  List<Parameter> _parametersFor(ContractFunction function) {
    final parameters = <Parameter>[];
    for (final param in function.parameters) {
      parameters.add(Parameter((b) => b
        ..name = param.name
        ..type = param.type.toDart()));
    }

    return parameters;
  }

  Code _bodyForImmutable(ContractFunction function) {
    final params = function.parameters.map((e) => refer(e.name)).toList();

    final outputs = function.outputs;
    Expression returnValue;
    if (outputs.length > 1) {
      returnValue = _resultClassFor(function).newInstance([refer('response')]);
    } else {
      returnValue = refer('response')
          .index(literalNum(0))
          .asA(function.outputs.single.type.toDart());
    }

    return Block((b) => b
      ..addExpression(_function(function).assignFinal('function'))
      ..addExpression(literalList(params).assignFinal('params'))
      ..addExpression(refer('read')
          .call([argFunction, argParams])
          .awaited
          .assignFinal('response'))
      ..addExpression(returnValue.returned));
  }

  Code _bodyForMutable(ContractFunction function) {
    final params = function.parameters.map((e) => refer(e.name)).toList();

    return Block((b) => b
      ..addExpression(_function(function).assignFinal('function'))
      ..addExpression(literalList(params).assignFinal('params'))
      ..addExpression(transactionType.newInstanceNamed(
        'callContract',
        const [],
        {
          'contract': refer('self'),
          'function': refer('function'),
          'parameters': refer('params'),
        },
      ).assignFinal('transaction'))
      ..addExpression(funWrite));
  }

  /// Creates a custom class encapsulating the return values of a [function]
  /// with multiple return values.
  Reference _resultClassFor(ContractFunction function) {
    return _functionToResultClass.putIfAbsent(function, () {
      final functionName = function.name;
      final name =
          '${functionName[0].toUpperCase()}${functionName.substring(1)}';
      return _generateResultClass(function.outputs, name);
    });
  }

  Reference _generateResultClass(List<FunctionParameter> params, String name) {
    final fields = <Field>[];
    final initializers = <Code>[];
    for (var i = 0; i < params.length; i++) {
      var name = params[i].name.isEmpty ? 'var${i + 1}' : params[i].name;
      name = name.replaceAll('_', '');

      final type = params[i].type.toDart();

      fields.add(Field((b) => b
        ..name = name
        ..type = type
        ..modifier = FieldModifier.final$));

      initializers
          .add(refer(name).assign(refer('response[$i]').asA(type)).code);
    }

    _additionalSpecs.add(Class((b) => b
      ..name = name
      ..fields.addAll(fields)
      ..constructors.add(Constructor((b) => b
        ..requiredParameters.add(Parameter((b) => b
          ..name = 'response'
          ..type = listify(dynamicType)))
        ..initializers.addAll(initializers)))));

    return refer(name);
  }

  void _methodForEvent(ContractEvent event, MethodBuilder b) {
    final name = event.name;
    final eventClass = _generateResultClass(
        event.components.map((e) => e.parameter).toList(), name);
    final nullableBlockNum = blockNum.rebuild((b) => b.isNullable = true);

    final mapper = Method(
      (b) => b
        ..requiredParameters.add(Parameter((b) => b
          ..name = 'result'
          ..type = filterEvent))
        ..body = Block(
          (b) => b
            ..addExpression(
                refer('event').property('decodeResults').call(const [
              // todo: Use nullChecked after https://github.com/dart-lang/code_builder/pull/325
              CodeExpression(Code('result.topics!')),
              CodeExpression(Code('result.data!')),
            ]).assignFinal('decoded'))
            ..addExpression(
                eventClass.newInstance([refer('decoded')]).returned),
        ),
    );

    b
      ..returns = streamOf(eventClass)
      ..name = '${name.substring(0, 1).toLowerCase()}${name.substring(1)}'
      ..optionalParameters.add(Parameter((b) => b
        ..name = 'fromBlock'
        ..named = true
        ..type = nullableBlockNum))
      ..optionalParameters.add(Parameter((b) => b
        ..name = 'toBlock'
        ..named = true
        ..type = nullableBlockNum))
      ..body = Block((b) => b
        ..addExpression(_event(event).assignFinal('event'))
        ..addExpression(filterOptions.newInstanceNamed('events', const [], {
          'contract': self,
          'event': refer('event'),
          'fromBlock': refer('fromBlock'),
          'toBlock': refer('toBlock'),
        }).assignFinal('filter'))
        ..addExpression(client
            .property('events')
            .call([refer('filter')])
            .property('map')
            .call([mapper.closure])
            .returned));
  }

  Expression _function(ContractFunction function) {
    return self.property('function').call([literalString(function.name)]);
  }

  Expression _event(ContractEvent event) {
    return self.property('event').call([literalString(event.name)]);
  }

  Reference _returnType(ContractFunction function) {
    if (!function.isConstant) {
      return futurize(string);
    } else if (function.outputs.isEmpty) {
      return futurize(refer('void'));
    } else if (function.outputs.length > 1) {
      return futurize(_resultClassFor(function));
    } else {
      return futurize(function.outputs[0].type.toDart());
    }
  }
}