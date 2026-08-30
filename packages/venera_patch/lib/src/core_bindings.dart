import 'dart:convert';
import 'dart:math' as math;

import 'package:venera_patch_vm/venera_patch_vm.dart';

/// The hand-written core binding surface: `dart:core` plus the few `dart:convert`
/// and `dart:math` members a fix routinely needs.
///
/// ## Why this is hand-written when the rest will be generated
///
/// Everything a patch can reach has to be bound explicitly — AOT Dart has no
/// reflection, so there is no way to call a member that no generated code names.
/// The repo's own public surface will come from build_runner, and the Flutter/SDK
/// surface from a declarative spec. But the core surface is different in kind:
/// it is small, it never changes between app versions, and every patch needs it.
/// Generating it would add a build step whose output is a constant.
///
/// ## Ids are stable forever
///
/// An id is baked into every payload compiled against this build. Renumbering
/// would silently redirect calls in already-published patches to different
/// members. So: **append only, never reuse, never renumber.** A retired member
/// keeps its id and starts throwing.
///
/// Ranges keep the numbering legible as this grows:
/// - `0x0100..0x01FF` String
/// - `0x0200..0x02FF` int / double / num
/// - `0x0300..0x03FF` List
/// - `0x0400..0x04FF` Map
/// - `0x0500..0x05FF` Set / Iterable
/// - `0x0600..0x06FF` Uri
/// - `0x0700..0x07FF` DateTime / Duration
/// - `0x0800..0x08FF` dart:convert
/// - `0x0900..0x09FF` dart:math
/// - `0x0A00..0x0AFF` RegExp
/// - `0x0B00..0x0BFF` constructors and statics
/// - `0x1000..0x10FF` type predicates (for `is` / `on T catch`)
///
/// Host-app members (`0x2000` and up) are added by the generated table, which
/// composes with this one.
abstract final class CoreIds {
  // --- String (0x0100) ---
  static const stringLength = 0x0100;
  static const stringIsEmpty = 0x0101;
  static const stringIsNotEmpty = 0x0102;
  static const stringToUpperCase = 0x0103;
  static const stringToLowerCase = 0x0104;
  static const stringTrim = 0x0105;
  static const stringTrimLeft = 0x0106;
  static const stringTrimRight = 0x0107;
  static const stringIndexOf = 0x0108;
  static const stringLastIndexOf = 0x0109;
  static const stringContains = 0x010A;
  static const stringStartsWith = 0x010B;
  static const stringEndsWith = 0x010C;
  static const stringSubstring = 0x010D;
  static const stringSplit = 0x010E;
  static const stringReplaceAll = 0x010F;
  static const stringReplaceFirst = 0x0110;
  static const stringCodeUnitAt = 0x0111;
  static const stringCompareTo = 0x0112;
  static const stringPadLeft = 0x0113;
  static const stringPadRight = 0x0114;
  static const stringCodeUnits = 0x0115;
  static const stringToString = 0x0116;
  static const stringHashCode = 0x0117;

  // --- Numbers (0x0200) ---
  static const numAbs = 0x0200;
  static const numToInt = 0x0201;
  static const numToDouble = 0x0202;
  static const numToString = 0x0203;
  static const numCompareTo = 0x0204;
  static const numClamp = 0x0205;
  static const numIsNaN = 0x0206;
  static const numIsFinite = 0x0207;
  static const numIsNegative = 0x0208;
  static const intIsEven = 0x0209;
  static const intIsOdd = 0x020A;
  static const doubleRound = 0x020B;
  static const doubleFloor = 0x020C;
  static const doubleCeil = 0x020D;
  static const doubleTruncate = 0x020E;
  static const doubleToStringAsFixed = 0x020F;
  static const intToRadixString = 0x0210;
  static const intBitLength = 0x0211;

  // --- List (0x0300) ---
  static const listLength = 0x0300;
  static const listIsEmpty = 0x0301;
  static const listIsNotEmpty = 0x0302;
  static const listFirst = 0x0303;
  static const listLast = 0x0304;
  static const listAdd = 0x0305;
  static const listAddAll = 0x0306;
  static const listRemove = 0x0307;
  static const listRemoveAt = 0x0308;
  static const listRemoveLast = 0x0309;
  static const listClear = 0x030A;
  static const listIndexOf = 0x030B;
  static const listContains = 0x030C;
  static const listSublist = 0x030D;
  static const listJoin = 0x030E;
  static const listReversed = 0x030F;
  static const listSort = 0x0310;
  static const listInsert = 0x0311;
  static const listToList = 0x0312;
  static const listToSet = 0x0313;
  static const listElementAt = 0x0314;
  static const listSkip = 0x0315;
  static const listTake = 0x0316;
  static const listWhere = 0x0317;
  static const listMap = 0x0318;
  static const listAny = 0x0319;
  static const listEvery = 0x031A;
  static const listFirstWhereOrNull = 0x031B;
  static const listExpand = 0x031C;
  static const listFold = 0x031D;

  // --- Map (0x0400) ---
  static const mapLength = 0x0400;
  static const mapIsEmpty = 0x0401;
  static const mapIsNotEmpty = 0x0402;
  static const mapGet = 0x0403;
  static const mapSet = 0x0404;
  static const mapContainsKey = 0x0405;
  static const mapContainsValue = 0x0406;
  static const mapRemove = 0x0407;
  static const mapClear = 0x0408;
  static const mapKeys = 0x0409;
  static const mapValues = 0x040A;
  static const mapPutIfAbsent = 0x040B;
  static const mapAddAll = 0x040C;
  static const mapEntriesKeys = 0x040D;

  // --- Set / Iterable (0x0500) ---
  static const setLength = 0x0500;
  static const setContains = 0x0501;
  static const setAdd = 0x0502;
  static const setRemove = 0x0503;
  static const setToList = 0x0504;
  static const setIsEmpty = 0x0505;
  static const setIsNotEmpty = 0x0506;
  static const setUnion = 0x0507;
  static const setIntersection = 0x0508;
  static const setDifference = 0x0509;

  // --- Uri (0x0600) ---
  static const uriHost = 0x0600;
  static const uriScheme = 0x0601;
  static const uriPath = 0x0602;
  static const uriQuery = 0x0603;
  static const uriFragment = 0x0604;
  static const uriPort = 0x0605;
  static const uriPathSegments = 0x0606;
  static const uriQueryParameters = 0x0607;
  static const uriToString = 0x0608;
  static const uriIsAbsolute = 0x0609;
  static const uriHasScheme = 0x060A;
  static const uriResolve = 0x060B;
  static const uriOrigin = 0x060C;
  static const uriAuthority = 0x060D;

  // --- DateTime / Duration (0x0700) ---
  static const dateTimeYear = 0x0700;
  static const dateTimeMonth = 0x0701;
  static const dateTimeDay = 0x0702;
  static const dateTimeHour = 0x0703;
  static const dateTimeMinute = 0x0704;
  static const dateTimeSecond = 0x0705;
  static const dateTimeMillisecondsSinceEpoch = 0x0706;
  static const dateTimeToIso8601String = 0x0707;
  static const dateTimeIsBefore = 0x0708;
  static const dateTimeIsAfter = 0x0709;
  static const dateTimeDifference = 0x070A;
  static const dateTimeAdd = 0x070B;
  static const dateTimeSubtract = 0x070C;
  static const durationInDays = 0x070D;
  static const durationInHours = 0x070E;
  static const durationInMinutes = 0x070F;
  static const durationInSeconds = 0x0710;
  static const durationInMilliseconds = 0x0711;

  // --- dart:convert (0x0800) ---
  static const jsonEncode = 0x0800;
  static const jsonDecode = 0x0801;
  static const base64Encode = 0x0802;
  static const base64Decode = 0x0803;
  static const utf8Encode = 0x0804;
  static const utf8Decode = 0x0805;

  // --- dart:math (0x0900) ---
  static const mathMin = 0x0900;
  static const mathMax = 0x0901;
  static const mathPow = 0x0902;
  static const mathSqrt = 0x0903;

  // --- RegExp (0x0A00) ---
  static const regExpNew = 0x0A00;
  static const regExpHasMatch = 0x0A01;
  static const regExpFirstMatchGroup = 0x0A02;
  static const regExpStringMatch = 0x0A03;
  static const regExpAllMatchesCount = 0x0A04;

  // --- Constructors and statics (0x0B00) ---
  static const intParse = 0x0B00;
  static const intTryParse = 0x0B01;
  static const doubleParse = 0x0B02;
  static const doubleTryParse = 0x0B03;
  static const uriParse = 0x0B04;
  static const uriTryParse = 0x0B05;
  static const dateTimeNow = 0x0B06;
  static const dateTimeFromMillis = 0x0B07;
  static const durationNew = 0x0B08;
  static const listEmpty = 0x0B09;
  static const mapEmpty = 0x0B0A;
  static const setEmpty = 0x0B0B;
  static const stringBufferNew = 0x0B0C;
  static const stringBufferWrite = 0x0B0D;
  static const stringBufferToString = 0x0B0E;
  static const exceptionNew = 0x0B0F;
  static const stateErrorNew = 0x0B10;
  static const argumentErrorNew = 0x0B11;

  // --- Future combinators (0x0C00) ---
  //
  // The interpreter can await, but only something that returns a Future. These
  // are the platform-neutral combinators; the app's own async surface (network,
  // storage, database) belongs in the generated app bindings, not here.
  //
  // `dart:io` is deliberately absent from this file. Adding it would drag a
  // platform dependency into the one binding table that is otherwise portable,
  // and it would widen the reachable surface with filesystem access that most
  // patches have no business holding.
  static const futureValue = 0x0C00;
  static const futureDelayedMs = 0x0C01;
  static const futureWait = 0x0C02;
  static const futureError = 0x0C03;

  // --- Type predicates (0x1000) ---
  static const typeString = 0x1000;
  static const typeInt = 0x1001;
  static const typeDouble = 0x1002;
  static const typeNum = 0x1003;
  static const typeBool = 0x1004;
  static const typeList = 0x1005;
  static const typeMap = 0x1006;
  static const typeSet = 0x1007;
  static const typeException = 0x1008;
  static const typeError = 0x1009;
  static const typeStateError = 0x100A;
  static const typeFormatException = 0x100B;
  static const typeArgumentError = 0x100C;
  static const typeRangeError = 0x100D;
  static const typeDateTime = 0x100E;
  static const typeDuration = 0x100F;
  static const typeUri = 0x1010;
  static const typeObject = 0x1011;
}

/// The core surface as a [HostBridge].
///
/// A `switch` on int, not a map: it compiles to a jump table, so a crossing costs
/// a bounds check and an indirect jump rather than a hash lookup. That matters —
/// interpreted code reaches the host constantly, and the interpreter is already
/// ~23x native.
///
/// Callbacks arrive as a plain Dart function — the VM hands out a tear-off of
/// its closure's `call`, not the closure object — so `where`/`map` and friends
/// work without this file knowing anything about the VM's internals.
///
/// That indirection is not incidental. A Dart class with a `call` method is
/// *callable* but is not a subtype of `Function`: `x as Function` throws. Casting
/// a callback here is therefore only safe because the VM hands over a real
/// function; the closure tests caught this the one time it did not.
final class CoreBindings implements HostBridge {
  const CoreBindings();

  @override
  bool isBound(int memberId) =>
      // Every id this file answers falls in the ranges below. Checked by range
      // rather than by a set literal so adding a member needs one edit, not two
      // that can drift apart.
      (memberId >= 0x0100 && memberId <= 0x0CFF) ||
      (memberId >= 0x1000 && memberId <= 0x10FF);

  @override
  bool isBoundType(int typeId) => typeId >= 0x1000 && typeId <= 0x10FF;

  @override
  String? describe(int memberId) => 'core#0x${memberId.toRadixString(16)}';

  @override
  bool isInstanceOf(int typeId, Object? value) => switch (typeId) {
        CoreIds.typeString => value is String,
        CoreIds.typeInt => value is int,
        CoreIds.typeDouble => value is double,
        CoreIds.typeNum => value is num,
        CoreIds.typeBool => value is bool,
        CoreIds.typeList => value is List,
        CoreIds.typeMap => value is Map,
        CoreIds.typeSet => value is Set,
        CoreIds.typeException => value is Exception,
        CoreIds.typeError => value is Error,
        CoreIds.typeStateError => value is StateError,
        CoreIds.typeFormatException => value is FormatException,
        CoreIds.typeArgumentError => value is ArgumentError,
        CoreIds.typeRangeError => value is RangeError,
        CoreIds.typeDateTime => value is DateTime,
        CoreIds.typeDuration => value is Duration,
        CoreIds.typeUri => value is Uri,
        CoreIds.typeObject => true,
        _ => throw UnboundMemberFault(typeId, 'no binding for type #$typeId'),
      };

  @override
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> a,
    Map<String, Object?>? named,
  ) {
    switch (memberId) {
      // --- String ---
      case CoreIds.stringLength:
        return (receiver as String).length;
      case CoreIds.stringIsEmpty:
        return (receiver as String).isEmpty;
      case CoreIds.stringIsNotEmpty:
        return (receiver as String).isNotEmpty;
      case CoreIds.stringToUpperCase:
        return (receiver as String).toUpperCase();
      case CoreIds.stringToLowerCase:
        return (receiver as String).toLowerCase();
      case CoreIds.stringTrim:
        return (receiver as String).trim();
      case CoreIds.stringTrimLeft:
        return (receiver as String).trimLeft();
      case CoreIds.stringTrimRight:
        return (receiver as String).trimRight();
      case CoreIds.stringIndexOf:
        return a.length > 1
            ? (receiver as String).indexOf(a[0] as Pattern, a[1] as int)
            : (receiver as String).indexOf(a[0] as Pattern);
      case CoreIds.stringLastIndexOf:
        return (receiver as String).lastIndexOf(a[0] as Pattern);
      case CoreIds.stringContains:
        return (receiver as String).contains(a[0] as Pattern);
      case CoreIds.stringStartsWith:
        return (receiver as String).startsWith(a[0] as Pattern);
      case CoreIds.stringEndsWith:
        return (receiver as String).endsWith(a[0] as String);
      case CoreIds.stringSubstring:
        return a.length > 1 && a[1] != null
            ? (receiver as String).substring(a[0] as int, a[1] as int)
            : (receiver as String).substring(a[0] as int);
      case CoreIds.stringSplit:
        return (receiver as String).split(a[0] as Pattern);
      case CoreIds.stringReplaceAll:
        return (receiver as String)
            .replaceAll(a[0] as Pattern, a[1] as String);
      case CoreIds.stringReplaceFirst:
        return (receiver as String)
            .replaceFirst(a[0] as Pattern, a[1] as String);
      case CoreIds.stringCodeUnitAt:
        return (receiver as String).codeUnitAt(a[0] as int);
      case CoreIds.stringCompareTo:
        return (receiver as String).compareTo(a[0] as String);
      case CoreIds.stringPadLeft:
        return (receiver as String)
            .padLeft(a[0] as int, a.length > 1 ? a[1] as String : ' ');
      case CoreIds.stringPadRight:
        return (receiver as String)
            .padRight(a[0] as int, a.length > 1 ? a[1] as String : ' ');
      case CoreIds.stringCodeUnits:
        return (receiver as String).codeUnits;
      case CoreIds.stringToString:
        return receiver.toString();
      case CoreIds.stringHashCode:
        return receiver.hashCode;

      // --- Numbers ---
      case CoreIds.numAbs:
        return (receiver as num).abs();
      case CoreIds.numToInt:
        return (receiver as num).toInt();
      case CoreIds.numToDouble:
        return (receiver as num).toDouble();
      case CoreIds.numToString:
        return (receiver as num).toString();
      case CoreIds.numCompareTo:
        return (receiver as num).compareTo(a[0] as num);
      case CoreIds.numClamp:
        return (receiver as num).clamp(a[0] as num, a[1] as num);
      case CoreIds.numIsNaN:
        return (receiver as num).isNaN;
      case CoreIds.numIsFinite:
        return (receiver as num).isFinite;
      case CoreIds.numIsNegative:
        return (receiver as num).isNegative;
      case CoreIds.intIsEven:
        return (receiver as int).isEven;
      case CoreIds.intIsOdd:
        return (receiver as int).isOdd;
      case CoreIds.doubleRound:
        return (receiver as num).round();
      case CoreIds.doubleFloor:
        return (receiver as num).floor();
      case CoreIds.doubleCeil:
        return (receiver as num).ceil();
      case CoreIds.doubleTruncate:
        return (receiver as num).truncate();
      case CoreIds.doubleToStringAsFixed:
        return (receiver as num).toStringAsFixed(a[0] as int);
      case CoreIds.intToRadixString:
        return (receiver as int).toRadixString(a[0] as int);
      case CoreIds.intBitLength:
        return (receiver as int).bitLength;

      // --- List ---
      case CoreIds.listLength:
        return (receiver as List).length;
      case CoreIds.listIsEmpty:
        return (receiver as List).isEmpty;
      case CoreIds.listIsNotEmpty:
        return (receiver as List).isNotEmpty;
      case CoreIds.listFirst:
        return (receiver as List).first;
      case CoreIds.listLast:
        return (receiver as List).last;
      case CoreIds.listAdd:
        (receiver as List).add(a[0]);
        return null;
      case CoreIds.listAddAll:
        (receiver as List).addAll(a[0] as Iterable);
        return null;
      case CoreIds.listRemove:
        return (receiver as List).remove(a[0]);
      case CoreIds.listRemoveAt:
        return (receiver as List).removeAt(a[0] as int);
      case CoreIds.listRemoveLast:
        return (receiver as List).removeLast();
      case CoreIds.listClear:
        (receiver as List).clear();
        return null;
      case CoreIds.listIndexOf:
        return (receiver as List).indexOf(a[0]);
      case CoreIds.listContains:
        return (receiver as List).contains(a[0]);
      case CoreIds.listSublist:
        return a.length > 1 && a[1] != null
            ? (receiver as List).sublist(a[0] as int, a[1] as int)
            : (receiver as List).sublist(a[0] as int);
      case CoreIds.listJoin:
        return (receiver as List).join(a.isEmpty ? '' : a[0] as String);
      case CoreIds.listReversed:
        return (receiver as List).reversed.toList();
      case CoreIds.listSort:
        // The comparator is a real Dart function (a tear-off of the VM
        // closure's `call`), so `sort` calls back into interpreted code without
        // knowing it.
        if (a.isEmpty || a[0] == null) {
          (receiver as List).sort();
        } else {
          final cmp = a[0] as Function;
          (receiver as List).sort((x, y) => cmp(x, y) as int);
        }
        return null;
      case CoreIds.listInsert:
        (receiver as List).insert(a[0] as int, a[1]);
        return null;
      case CoreIds.listToList:
        return (receiver as Iterable).toList();
      case CoreIds.listToSet:
        return (receiver as Iterable).toSet();
      case CoreIds.listElementAt:
        return (receiver as Iterable).elementAt(a[0] as int);
      case CoreIds.listSkip:
        return (receiver as Iterable).skip(a[0] as int).toList();
      case CoreIds.listTake:
        return (receiver as Iterable).take(a[0] as int).toList();
      case CoreIds.listWhere:
        final f = a[0] as Function;
        return (receiver as Iterable).where((e) => f(e) as bool).toList();
      case CoreIds.listMap:
        final f = a[0] as Function;
        return (receiver as Iterable).map<Object?>((e) => f(e)).toList();
      case CoreIds.listAny:
        final f = a[0] as Function;
        return (receiver as Iterable).any((e) => f(e) as bool);
      case CoreIds.listEvery:
        final f = a[0] as Function;
        return (receiver as Iterable).every((e) => f(e) as bool);
      case CoreIds.listFirstWhereOrNull:
        final f = a[0] as Function;
        for (final e in receiver as Iterable) {
          if (f(e) as bool) return e;
        }
        return null;
      case CoreIds.listExpand:
        final f = a[0] as Function;
        return (receiver as Iterable)
            .expand<Object?>((e) => f(e) as Iterable)
            .toList();
      case CoreIds.listFold:
        final f = a[1] as Function;
        var acc = a[0];
        for (final e in receiver as Iterable) {
          acc = f(acc, e);
        }
        return acc;

      // --- Map ---
      case CoreIds.mapLength:
        return (receiver as Map).length;
      case CoreIds.mapIsEmpty:
        return (receiver as Map).isEmpty;
      case CoreIds.mapIsNotEmpty:
        return (receiver as Map).isNotEmpty;
      case CoreIds.mapGet:
        return (receiver as Map)[a[0]];
      case CoreIds.mapSet:
        (receiver as Map)[a[0]] = a[1];
        return null;
      case CoreIds.mapContainsKey:
        return (receiver as Map).containsKey(a[0]);
      case CoreIds.mapContainsValue:
        return (receiver as Map).containsValue(a[0]);
      case CoreIds.mapRemove:
        return (receiver as Map).remove(a[0]);
      case CoreIds.mapClear:
        (receiver as Map).clear();
        return null;
      case CoreIds.mapKeys:
        return (receiver as Map).keys.toList();
      case CoreIds.mapValues:
        return (receiver as Map).values.toList();
      case CoreIds.mapPutIfAbsent:
        final f = a[1] as Function;
        return (receiver as Map).putIfAbsent(a[0], () => f());
      case CoreIds.mapAddAll:
        (receiver as Map).addAll(a[0] as Map);
        return null;
      case CoreIds.mapEntriesKeys:
        return (receiver as Map).keys.toList();

      // --- Set ---
      case CoreIds.setLength:
        return (receiver as Set).length;
      case CoreIds.setContains:
        return (receiver as Set).contains(a[0]);
      case CoreIds.setAdd:
        return (receiver as Set).add(a[0]);
      case CoreIds.setRemove:
        return (receiver as Set).remove(a[0]);
      case CoreIds.setToList:
        return (receiver as Set).toList();
      case CoreIds.setIsEmpty:
        return (receiver as Set).isEmpty;
      case CoreIds.setIsNotEmpty:
        return (receiver as Set).isNotEmpty;
      case CoreIds.setUnion:
        return (receiver as Set).union(Set.of(a[0] as Iterable));
      case CoreIds.setIntersection:
        return (receiver as Set).intersection(Set.of(a[0] as Iterable));
      case CoreIds.setDifference:
        return (receiver as Set).difference(Set.of(a[0] as Iterable));

      // --- Uri ---
      case CoreIds.uriHost:
        return (receiver as Uri).host;
      case CoreIds.uriScheme:
        return (receiver as Uri).scheme;
      case CoreIds.uriPath:
        return (receiver as Uri).path;
      case CoreIds.uriQuery:
        return (receiver as Uri).query;
      case CoreIds.uriFragment:
        return (receiver as Uri).fragment;
      case CoreIds.uriPort:
        return (receiver as Uri).port;
      case CoreIds.uriPathSegments:
        return (receiver as Uri).pathSegments.toList();
      case CoreIds.uriQueryParameters:
        return Map<String, String>.from((receiver as Uri).queryParameters);
      case CoreIds.uriToString:
        return (receiver as Uri).toString();
      case CoreIds.uriIsAbsolute:
        return (receiver as Uri).isAbsolute;
      case CoreIds.uriHasScheme:
        return (receiver as Uri).hasScheme;
      case CoreIds.uriResolve:
        return (receiver as Uri).resolve(a[0] as String);
      case CoreIds.uriOrigin:
        return (receiver as Uri).origin;
      case CoreIds.uriAuthority:
        return (receiver as Uri).authority;

      // --- DateTime / Duration ---
      case CoreIds.dateTimeYear:
        return (receiver as DateTime).year;
      case CoreIds.dateTimeMonth:
        return (receiver as DateTime).month;
      case CoreIds.dateTimeDay:
        return (receiver as DateTime).day;
      case CoreIds.dateTimeHour:
        return (receiver as DateTime).hour;
      case CoreIds.dateTimeMinute:
        return (receiver as DateTime).minute;
      case CoreIds.dateTimeSecond:
        return (receiver as DateTime).second;
      case CoreIds.dateTimeMillisecondsSinceEpoch:
        return (receiver as DateTime).millisecondsSinceEpoch;
      case CoreIds.dateTimeToIso8601String:
        return (receiver as DateTime).toIso8601String();
      case CoreIds.dateTimeIsBefore:
        return (receiver as DateTime).isBefore(a[0] as DateTime);
      case CoreIds.dateTimeIsAfter:
        return (receiver as DateTime).isAfter(a[0] as DateTime);
      case CoreIds.dateTimeDifference:
        return (receiver as DateTime).difference(a[0] as DateTime);
      case CoreIds.dateTimeAdd:
        return (receiver as DateTime).add(a[0] as Duration);
      case CoreIds.dateTimeSubtract:
        return (receiver as DateTime).subtract(a[0] as Duration);
      case CoreIds.durationInDays:
        return (receiver as Duration).inDays;
      case CoreIds.durationInHours:
        return (receiver as Duration).inHours;
      case CoreIds.durationInMinutes:
        return (receiver as Duration).inMinutes;
      case CoreIds.durationInSeconds:
        return (receiver as Duration).inSeconds;
      case CoreIds.durationInMilliseconds:
        return (receiver as Duration).inMilliseconds;

      // --- dart:convert ---
      case CoreIds.jsonEncode:
        return jsonEncode(a[0]);
      case CoreIds.jsonDecode:
        return jsonDecode(a[0] as String);
      case CoreIds.base64Encode:
        return base64Encode(List<int>.from(a[0] as Iterable));
      case CoreIds.base64Decode:
        return base64Decode(a[0] as String);
      case CoreIds.utf8Encode:
        return utf8.encode(a[0] as String);
      case CoreIds.utf8Decode:
        return utf8.decode(List<int>.from(a[0] as Iterable));

      // --- dart:math ---
      case CoreIds.mathMin:
        return math.min(a[0] as num, a[1] as num);
      case CoreIds.mathMax:
        return math.max(a[0] as num, a[1] as num);
      case CoreIds.mathPow:
        return math.pow(a[0] as num, a[1] as num);
      case CoreIds.mathSqrt:
        return math.sqrt(a[0] as num);

      // --- RegExp ---
      case CoreIds.regExpNew:
        return RegExp(a[0] as String);
      case CoreIds.regExpHasMatch:
        return (receiver as RegExp).hasMatch(a[0] as String);
      case CoreIds.regExpFirstMatchGroup:
        // Returns the captured group directly: a Match object would need its own
        // binding, and every real use immediately reads a group.
        final m = (receiver as RegExp).firstMatch(a[0] as String);
        return m?.group(a.length > 1 ? a[1] as int : 0);
      case CoreIds.regExpStringMatch:
        return (receiver as RegExp).stringMatch(a[0] as String);
      case CoreIds.regExpAllMatchesCount:
        return (receiver as RegExp).allMatches(a[0] as String).length;

      // --- Constructors and statics ---
      case CoreIds.intParse:
        return int.parse(a[0] as String);
      case CoreIds.intTryParse:
        return int.tryParse(a[0] as String);
      case CoreIds.doubleParse:
        return double.parse(a[0] as String);
      case CoreIds.doubleTryParse:
        return double.tryParse(a[0] as String);
      case CoreIds.uriParse:
        return Uri.parse(a[0] as String);
      case CoreIds.uriTryParse:
        return Uri.tryParse(a[0] as String);
      case CoreIds.dateTimeNow:
        return DateTime.now();
      case CoreIds.dateTimeFromMillis:
        return DateTime.fromMillisecondsSinceEpoch(a[0] as int);
      case CoreIds.durationNew:
        return Duration(
          days: (named?['days'] as int?) ?? 0,
          hours: (named?['hours'] as int?) ?? 0,
          minutes: (named?['minutes'] as int?) ?? 0,
          seconds: (named?['seconds'] as int?) ?? 0,
          milliseconds: (named?['milliseconds'] as int?) ?? 0,
        );
      case CoreIds.listEmpty:
        return <Object?>[];
      case CoreIds.mapEmpty:
        return <Object?, Object?>{};
      case CoreIds.setEmpty:
        return <Object?>{};
      case CoreIds.stringBufferNew:
        return StringBuffer();
      case CoreIds.stringBufferWrite:
        (receiver as StringBuffer).write(a[0]);
        return null;
      case CoreIds.stringBufferToString:
        return (receiver as StringBuffer).toString();
      case CoreIds.exceptionNew:
        return Exception(a.isEmpty ? null : a[0]);
      case CoreIds.stateErrorNew:
        return StateError(a[0] as String);
      case CoreIds.argumentErrorNew:
        return ArgumentError(a.isEmpty ? null : a[0]);

      // --- Future combinators ---
      //
      // These return Futures into interpreted code, which awaits them through
      // the host's own async machinery. No signature change was needed for that:
      // `invoke` returns Object?, and a Future is an Object.
      case CoreIds.futureValue:
        return Future<Object?>.value(a.isEmpty ? null : a[0]);
      case CoreIds.futureDelayedMs:
        return Future<Object?>.delayed(
          Duration(milliseconds: a[0] as int),
          a.length > 1 ? () => a[1] : null,
        );
      case CoreIds.futureWait:
        // Accepts the list of futures a patch built up, e.g. one per download.
        // Non-futures pass through, matching `Future.wait`'s tolerance for
        // already-resolved values.
        final items = a[0] as Iterable;
        return Future.wait(
          items.map((e) => e is Future ? e : Future<Object?>.value(e)),
        );
      case CoreIds.futureError:
        return Future<Object?>.error(
          a.isEmpty ? StateError('patch raised an async error') : a[0]!,
        );
    }
    throw UnboundMemberFault(memberId);
  }
}

/// Composes the core surface with the generated host-app surface.
///
/// The app's own bindings (stage 3) implement [HostBridge] and are layered on
/// top: this tries [primary] first and falls back to [CoreBindings]. Ids never
/// overlap — core owns `0x0100..0x10FF`, the app starts at `0x2000` — so the
/// order is a formality rather than a precedence rule.
final class LayeredHostBridge implements HostBridge {
  const LayeredHostBridge(this.primary, [this.fallback = const CoreBindings()]);

  final HostBridge primary;
  final HostBridge fallback;

  @override
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> positional,
    Map<String, Object?>? named,
  ) =>
      primary.isBound(memberId)
          ? primary.invoke(memberId, receiver, positional, named)
          : fallback.invoke(memberId, receiver, positional, named);

  @override
  bool isBound(int memberId) =>
      primary.isBound(memberId) || fallback.isBound(memberId);

  @override
  bool isBoundType(int typeId) =>
      primary.isBoundType(typeId) || fallback.isBoundType(typeId);

  @override
  String? describe(int memberId) =>
      primary.isBound(memberId) ? primary.describe(memberId)
          : fallback.describe(memberId);

  @override
  bool isInstanceOf(int typeId, Object? value) =>
      primary.isBoundType(typeId)
          ? primary.isInstanceOf(typeId, value)
          : fallback.isInstanceOf(typeId, value);
}
