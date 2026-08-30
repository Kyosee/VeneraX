import 'core_bindings.dart';

/// The compiler-facing half of [CoreBindings].
///
/// [CoreBindings] answers "given id 0x0108, do the thing". This answers "given
/// the source text `s.indexOf(...)`, which id is that" — the mapping the patch
/// compiler needs to turn Dart into VIR.
///
/// ## Why this is a separate, hand-written table
///
/// The obvious alternative is to derive it from the dispatch switch. But the
/// switch is a `switch` precisely because that compiles to a jump table, and a
/// jump table has no reflectable structure at run time. Deriving keys from it
/// would mean either shipping metadata alongside every case (paid for in every
/// release binary, to serve a tool that never ships) or code-generating both
/// halves from a third description (a build step, and a new thing to keep in
/// sync).
///
/// So the two halves are written by hand and *pinned together by a test*:
/// `core_surface_test.dart` reads `core_bindings.dart`, extracts every declared
/// id, and fails if any is missing from this table. Drift is caught in CI, which
/// is the property that actually matters — a missing key would otherwise surface
/// as "this app build cannot reach that member" for an API that is in fact
/// bound, sending a patch author off to add a binding that already exists.
///
/// ## Key format
///
/// Keys match what the compiler asks for:
///
/// * instance member — `Receiver.member`, using the *static* type name
///   (`String.indexOf`, `List.add`)
/// * static member or constructor — `Type.name`, with `new` for the unnamed
///   constructor (`int.parse`, `RegExp.new`, `DateTime.now`)
/// * top-level function — the bare name (`jsonDecode`)
///
/// One id may have several keys. `num.abs`, `int.abs` and `double.abs` are all
/// [CoreIds.numAbs], because the compiler keys on the receiver's static type and
/// a patch writing `count.abs()` has an `int` in hand, not a `num`.
abstract final class CoreSurface {
  /// Member key to id. See the class doc for the key format.
  static const Map<String, int> members = {
    // --- String ---
    'String.length': CoreIds.stringLength,
    'String.isEmpty': CoreIds.stringIsEmpty,
    'String.isNotEmpty': CoreIds.stringIsNotEmpty,
    'String.toUpperCase': CoreIds.stringToUpperCase,
    'String.toLowerCase': CoreIds.stringToLowerCase,
    'String.trim': CoreIds.stringTrim,
    'String.trimLeft': CoreIds.stringTrimLeft,
    'String.trimRight': CoreIds.stringTrimRight,
    'String.indexOf': CoreIds.stringIndexOf,
    'String.lastIndexOf': CoreIds.stringLastIndexOf,
    'String.contains': CoreIds.stringContains,
    'String.startsWith': CoreIds.stringStartsWith,
    'String.endsWith': CoreIds.stringEndsWith,
    'String.substring': CoreIds.stringSubstring,
    'String.split': CoreIds.stringSplit,
    'String.replaceAll': CoreIds.stringReplaceAll,
    'String.replaceFirst': CoreIds.stringReplaceFirst,
    'String.codeUnitAt': CoreIds.stringCodeUnitAt,
    'String.compareTo': CoreIds.stringCompareTo,
    'String.padLeft': CoreIds.stringPadLeft,
    'String.padRight': CoreIds.stringPadRight,
    'String.codeUnits': CoreIds.stringCodeUnits,
    'String.toString': CoreIds.stringToString,
    'String.hashCode': CoreIds.stringHashCode,

    // --- num / int / double ---
    //
    // Listed under every receiver type a patch may hold. The compiler keys on
    // the static type, so `int.abs` and `num.abs` are different lookups even
    // though they are the same operation.
    'num.abs': CoreIds.numAbs,
    'int.abs': CoreIds.numAbs,
    'double.abs': CoreIds.numAbs,
    'num.toInt': CoreIds.numToInt,
    'double.toInt': CoreIds.numToInt,
    'int.toInt': CoreIds.numToInt,
    'num.toDouble': CoreIds.numToDouble,
    'int.toDouble': CoreIds.numToDouble,
    'double.toDouble': CoreIds.numToDouble,
    'num.toString': CoreIds.numToString,
    'int.toString': CoreIds.numToString,
    'double.toString': CoreIds.numToString,
    'num.compareTo': CoreIds.numCompareTo,
    'int.compareTo': CoreIds.numCompareTo,
    'double.compareTo': CoreIds.numCompareTo,
    'num.clamp': CoreIds.numClamp,
    'int.clamp': CoreIds.numClamp,
    'double.clamp': CoreIds.numClamp,
    'num.isNaN': CoreIds.numIsNaN,
    'double.isNaN': CoreIds.numIsNaN,
    'num.isFinite': CoreIds.numIsFinite,
    'double.isFinite': CoreIds.numIsFinite,
    'num.isNegative': CoreIds.numIsNegative,
    'int.isNegative': CoreIds.numIsNegative,
    'double.isNegative': CoreIds.numIsNegative,
    'int.isEven': CoreIds.intIsEven,
    'int.isOdd': CoreIds.intIsOdd,
    'double.round': CoreIds.doubleRound,
    'num.round': CoreIds.doubleRound,
    'double.floor': CoreIds.doubleFloor,
    'num.floor': CoreIds.doubleFloor,
    'double.ceil': CoreIds.doubleCeil,
    'num.ceil': CoreIds.doubleCeil,
    'double.truncate': CoreIds.doubleTruncate,
    'num.truncate': CoreIds.doubleTruncate,
    'double.toStringAsFixed': CoreIds.doubleToStringAsFixed,
    'num.toStringAsFixed': CoreIds.doubleToStringAsFixed,
    'int.toRadixString': CoreIds.intToRadixString,
    'int.bitLength': CoreIds.intBitLength,

    // --- List / Iterable ---
    //
    // Both receivers, because `.map()` returns an Iterable and a patch chaining
    // `.where().map()` has an Iterable in hand for the second call.
    'List.length': CoreIds.listLength,
    'Iterable.length': CoreIds.listLength,
    'List.isEmpty': CoreIds.listIsEmpty,
    'Iterable.isEmpty': CoreIds.listIsEmpty,
    'List.isNotEmpty': CoreIds.listIsNotEmpty,
    'Iterable.isNotEmpty': CoreIds.listIsNotEmpty,
    'List.first': CoreIds.listFirst,
    'Iterable.first': CoreIds.listFirst,
    'List.last': CoreIds.listLast,
    'Iterable.last': CoreIds.listLast,
    'List.add': CoreIds.listAdd,
    'List.addAll': CoreIds.listAddAll,
    'List.remove': CoreIds.listRemove,
    'List.removeAt': CoreIds.listRemoveAt,
    'List.removeLast': CoreIds.listRemoveLast,
    'List.clear': CoreIds.listClear,
    'List.indexOf': CoreIds.listIndexOf,
    'List.contains': CoreIds.listContains,
    'Iterable.contains': CoreIds.listContains,
    'List.sublist': CoreIds.listSublist,
    'List.join': CoreIds.listJoin,
    'Iterable.join': CoreIds.listJoin,
    'List.reversed': CoreIds.listReversed,
    'List.sort': CoreIds.listSort,
    'List.insert': CoreIds.listInsert,
    'List.toList': CoreIds.listToList,
    'Iterable.toList': CoreIds.listToList,
    'List.toSet': CoreIds.listToSet,
    'Iterable.toSet': CoreIds.listToSet,
    'List.elementAt': CoreIds.listElementAt,
    'Iterable.elementAt': CoreIds.listElementAt,
    'List.skip': CoreIds.listSkip,
    'Iterable.skip': CoreIds.listSkip,
    'List.take': CoreIds.listTake,
    'Iterable.take': CoreIds.listTake,
    'List.where': CoreIds.listWhere,
    'Iterable.where': CoreIds.listWhere,
    'List.map': CoreIds.listMap,
    'Iterable.map': CoreIds.listMap,
    'List.any': CoreIds.listAny,
    'Iterable.any': CoreIds.listAny,
    'List.every': CoreIds.listEvery,
    'Iterable.every': CoreIds.listEvery,
    'List.firstWhereOrNull': CoreIds.listFirstWhereOrNull,
    'Iterable.firstWhereOrNull': CoreIds.listFirstWhereOrNull,
    'List.expand': CoreIds.listExpand,
    'Iterable.expand': CoreIds.listExpand,
    'List.fold': CoreIds.listFold,
    'Iterable.fold': CoreIds.listFold,

    // --- Map ---
    'Map.length': CoreIds.mapLength,
    'Map.isEmpty': CoreIds.mapIsEmpty,
    'Map.isNotEmpty': CoreIds.mapIsNotEmpty,
    // Indexing compiles to an `index` node for List and Map alike, so these two
    // exist for the rare explicit call rather than for `m[k]`.
    'Map.[]': CoreIds.mapGet,
    'Map.[]=': CoreIds.mapSet,
    'Map.containsKey': CoreIds.mapContainsKey,
    'Map.containsValue': CoreIds.mapContainsValue,
    'Map.remove': CoreIds.mapRemove,
    'Map.clear': CoreIds.mapClear,
    'Map.keys': CoreIds.mapKeys,
    'Map.values': CoreIds.mapValues,
    'Map.putIfAbsent': CoreIds.mapPutIfAbsent,
    'Map.addAll': CoreIds.mapAddAll,
    // `entries` would need a MapEntry binding; every real use immediately reads
    // the keys, so that is what this returns.
    'Map.entries': CoreIds.mapEntriesKeys,

    // --- Set ---
    'Set.length': CoreIds.setLength,
    'Set.contains': CoreIds.setContains,
    'Set.add': CoreIds.setAdd,
    'Set.remove': CoreIds.setRemove,
    'Set.toList': CoreIds.setToList,
    'Set.isEmpty': CoreIds.setIsEmpty,
    'Set.isNotEmpty': CoreIds.setIsNotEmpty,
    'Set.union': CoreIds.setUnion,
    'Set.intersection': CoreIds.setIntersection,
    'Set.difference': CoreIds.setDifference,

    // --- Uri ---
    'Uri.host': CoreIds.uriHost,
    'Uri.scheme': CoreIds.uriScheme,
    'Uri.path': CoreIds.uriPath,
    'Uri.query': CoreIds.uriQuery,
    'Uri.fragment': CoreIds.uriFragment,
    'Uri.port': CoreIds.uriPort,
    'Uri.pathSegments': CoreIds.uriPathSegments,
    'Uri.queryParameters': CoreIds.uriQueryParameters,
    'Uri.toString': CoreIds.uriToString,
    'Uri.isAbsolute': CoreIds.uriIsAbsolute,
    'Uri.hasScheme': CoreIds.uriHasScheme,
    'Uri.resolve': CoreIds.uriResolve,
    'Uri.origin': CoreIds.uriOrigin,
    'Uri.authority': CoreIds.uriAuthority,

    // --- DateTime / Duration ---
    'DateTime.year': CoreIds.dateTimeYear,
    'DateTime.month': CoreIds.dateTimeMonth,
    'DateTime.day': CoreIds.dateTimeDay,
    'DateTime.hour': CoreIds.dateTimeHour,
    'DateTime.minute': CoreIds.dateTimeMinute,
    'DateTime.second': CoreIds.dateTimeSecond,
    'DateTime.millisecondsSinceEpoch': CoreIds.dateTimeMillisecondsSinceEpoch,
    'DateTime.toIso8601String': CoreIds.dateTimeToIso8601String,
    'DateTime.isBefore': CoreIds.dateTimeIsBefore,
    'DateTime.isAfter': CoreIds.dateTimeIsAfter,
    'DateTime.difference': CoreIds.dateTimeDifference,
    'DateTime.add': CoreIds.dateTimeAdd,
    'DateTime.subtract': CoreIds.dateTimeSubtract,
    'Duration.inDays': CoreIds.durationInDays,
    'Duration.inHours': CoreIds.durationInHours,
    'Duration.inMinutes': CoreIds.durationInMinutes,
    'Duration.inSeconds': CoreIds.durationInSeconds,
    'Duration.inMilliseconds': CoreIds.durationInMilliseconds,

    // --- dart:convert, as top-level functions ---
    'jsonEncode': CoreIds.jsonEncode,
    'jsonDecode': CoreIds.jsonDecode,
    'base64Encode': CoreIds.base64Encode,
    'base64Decode': CoreIds.base64Decode,
    // utf8 is an object in Dart, so these read as member calls on it.
    'Utf8Codec.encode': CoreIds.utf8Encode,
    'Utf8Codec.decode': CoreIds.utf8Decode,

    // --- dart:math ---
    'math.min': CoreIds.mathMin,
    'math.max': CoreIds.mathMax,
    'math.pow': CoreIds.mathPow,
    'math.sqrt': CoreIds.mathSqrt,
    // Also without a prefix, for `import 'dart:math';` without `as math`.
    'min': CoreIds.mathMin,
    'max': CoreIds.mathMax,
    'pow': CoreIds.mathPow,
    'sqrt': CoreIds.mathSqrt,

    // --- RegExp ---
    'RegExp.new': CoreIds.regExpNew,
    'RegExp.hasMatch': CoreIds.regExpHasMatch,
    // Returns the captured group directly; a Match object would need bindings of
    // its own and every real use reads a group immediately.
    'RegExp.firstMatch': CoreIds.regExpFirstMatchGroup,
    'RegExp.stringMatch': CoreIds.regExpStringMatch,
    'RegExp.allMatches': CoreIds.regExpAllMatchesCount,

    // --- Statics and constructors ---
    'int.parse': CoreIds.intParse,
    'int.tryParse': CoreIds.intTryParse,
    'double.parse': CoreIds.doubleParse,
    'double.tryParse': CoreIds.doubleTryParse,
    'Uri.parse': CoreIds.uriParse,
    'Uri.tryParse': CoreIds.uriTryParse,
    'DateTime.now': CoreIds.dateTimeNow,
    'DateTime.fromMillisecondsSinceEpoch': CoreIds.dateTimeFromMillis,
    'Duration.new': CoreIds.durationNew,
    'List.empty': CoreIds.listEmpty,
    'Map.new': CoreIds.mapEmpty,
    'Set.new': CoreIds.setEmpty,
    'StringBuffer.new': CoreIds.stringBufferNew,
    'StringBuffer.write': CoreIds.stringBufferWrite,
    'StringBuffer.toString': CoreIds.stringBufferToString,
    'Exception.new': CoreIds.exceptionNew,
    'StateError.new': CoreIds.stateErrorNew,
    'ArgumentError.new': CoreIds.argumentErrorNew,

    // --- Future ---
    'Future.value': CoreIds.futureValue,
    'Future.delayed': CoreIds.futureDelayedMs,
    'Future.wait': CoreIds.futureWait,
    'Future.error': CoreIds.futureError,
  };

  /// Type key to id, for `is` / `as` and `on T catch`.
  static const Map<String, int> types = {
    'String': CoreIds.typeString,
    'int': CoreIds.typeInt,
    'double': CoreIds.typeDouble,
    'num': CoreIds.typeNum,
    'bool': CoreIds.typeBool,
    'List': CoreIds.typeList,
    'Map': CoreIds.typeMap,
    'Set': CoreIds.typeSet,
    'Exception': CoreIds.typeException,
    'Error': CoreIds.typeError,
    'StateError': CoreIds.typeStateError,
    'FormatException': CoreIds.typeFormatException,
    'ArgumentError': CoreIds.typeArgumentError,
    'RangeError': CoreIds.typeRangeError,
    'DateTime': CoreIds.typeDateTime,
    'Duration': CoreIds.typeDuration,
    'Uri': CoreIds.typeUri,
    'Object': CoreIds.typeObject,
  };
}
