// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'player.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$PlayerEvent {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'PlayerEvent()';
}


}

/// @nodoc
class $PlayerEventCopyWith<$Res>  {
$PlayerEventCopyWith(PlayerEvent _, $Res Function(PlayerEvent) __);
}


/// Adds pattern-matching-related methods to [PlayerEvent].
extension PlayerEventPatterns on PlayerEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( PlayerEvent_Loaded value)?  loaded,TResult Function( PlayerEvent_Path value)?  path,TResult Function( PlayerEvent_Playing value)?  playing,TResult Function( PlayerEvent_Position value)?  position,TResult Function( PlayerEvent_Ended value)?  ended,TResult Function( PlayerEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case PlayerEvent_Loaded() when loaded != null:
return loaded(_that);case PlayerEvent_Path() when path != null:
return path(_that);case PlayerEvent_Playing() when playing != null:
return playing(_that);case PlayerEvent_Position() when position != null:
return position(_that);case PlayerEvent_Ended() when ended != null:
return ended(_that);case PlayerEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( PlayerEvent_Loaded value)  loaded,required TResult Function( PlayerEvent_Path value)  path,required TResult Function( PlayerEvent_Playing value)  playing,required TResult Function( PlayerEvent_Position value)  position,required TResult Function( PlayerEvent_Ended value)  ended,required TResult Function( PlayerEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case PlayerEvent_Loaded():
return loaded(_that);case PlayerEvent_Path():
return path(_that);case PlayerEvent_Playing():
return playing(_that);case PlayerEvent_Position():
return position(_that);case PlayerEvent_Ended():
return ended(_that);case PlayerEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( PlayerEvent_Loaded value)?  loaded,TResult? Function( PlayerEvent_Path value)?  path,TResult? Function( PlayerEvent_Playing value)?  playing,TResult? Function( PlayerEvent_Position value)?  position,TResult? Function( PlayerEvent_Ended value)?  ended,TResult? Function( PlayerEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case PlayerEvent_Loaded() when loaded != null:
return loaded(_that);case PlayerEvent_Path() when path != null:
return path(_that);case PlayerEvent_Playing() when playing != null:
return playing(_that);case PlayerEvent_Position() when position != null:
return position(_that);case PlayerEvent_Ended() when ended != null:
return ended(_that);case PlayerEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( TrackInfo track,  int index)?  loaded,TResult Function( SignalPath path)?  path,TResult Function( bool playing)?  playing,TResult Function( double secs)?  position,TResult Function()?  ended,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case PlayerEvent_Loaded() when loaded != null:
return loaded(_that.track,_that.index);case PlayerEvent_Path() when path != null:
return path(_that.path);case PlayerEvent_Playing() when playing != null:
return playing(_that.playing);case PlayerEvent_Position() when position != null:
return position(_that.secs);case PlayerEvent_Ended() when ended != null:
return ended();case PlayerEvent_Error() when error != null:
return error(_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( TrackInfo track,  int index)  loaded,required TResult Function( SignalPath path)  path,required TResult Function( bool playing)  playing,required TResult Function( double secs)  position,required TResult Function()  ended,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case PlayerEvent_Loaded():
return loaded(_that.track,_that.index);case PlayerEvent_Path():
return path(_that.path);case PlayerEvent_Playing():
return playing(_that.playing);case PlayerEvent_Position():
return position(_that.secs);case PlayerEvent_Ended():
return ended();case PlayerEvent_Error():
return error(_that.message);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( TrackInfo track,  int index)?  loaded,TResult? Function( SignalPath path)?  path,TResult? Function( bool playing)?  playing,TResult? Function( double secs)?  position,TResult? Function()?  ended,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case PlayerEvent_Loaded() when loaded != null:
return loaded(_that.track,_that.index);case PlayerEvent_Path() when path != null:
return path(_that.path);case PlayerEvent_Playing() when playing != null:
return playing(_that.playing);case PlayerEvent_Position() when position != null:
return position(_that.secs);case PlayerEvent_Ended() when ended != null:
return ended();case PlayerEvent_Error() when error != null:
return error(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class PlayerEvent_Loaded extends PlayerEvent {
  const PlayerEvent_Loaded({required this.track, required this.index}): super._();
  

 final  TrackInfo track;
 final  int index;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayerEvent_LoadedCopyWith<PlayerEvent_Loaded> get copyWith => _$PlayerEvent_LoadedCopyWithImpl<PlayerEvent_Loaded>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent_Loaded&&(identical(other.track, track) || other.track == track)&&(identical(other.index, index) || other.index == index));
}


@override
int get hashCode {
    return Object.hash(runtimeType,track,index);
}

@override
String toString() {
    return 'PlayerEvent.loaded(track: $track, index: $index)';
}


}

/// @nodoc
abstract mixin class $PlayerEvent_LoadedCopyWith<$Res> implements $PlayerEventCopyWith<$Res> {
  factory $PlayerEvent_LoadedCopyWith(PlayerEvent_Loaded value, $Res Function(PlayerEvent_Loaded) _then) = _$PlayerEvent_LoadedCopyWithImpl;
@useResult
$Res call({
 TrackInfo track, int index
});




}
/// @nodoc
class _$PlayerEvent_LoadedCopyWithImpl<$Res>
    implements $PlayerEvent_LoadedCopyWith<$Res> {
  _$PlayerEvent_LoadedCopyWithImpl(this._self, this._then);

  final PlayerEvent_Loaded _self;
  final $Res Function(PlayerEvent_Loaded) _then;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? track = null,Object? index = null,}) {
  return _then(PlayerEvent_Loaded(
track: null == track ? _self.track : track // ignore: cast_nullable_to_non_nullable
as TrackInfo,index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class PlayerEvent_Path extends PlayerEvent {
  const PlayerEvent_Path({required this.path}): super._();
  

 final  SignalPath path;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayerEvent_PathCopyWith<PlayerEvent_Path> get copyWith => _$PlayerEvent_PathCopyWithImpl<PlayerEvent_Path>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent_Path&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode {
    return Object.hash(runtimeType,path);
}

@override
String toString() {
    return 'PlayerEvent.path(path: $path)';
}


}

/// @nodoc
abstract mixin class $PlayerEvent_PathCopyWith<$Res> implements $PlayerEventCopyWith<$Res> {
  factory $PlayerEvent_PathCopyWith(PlayerEvent_Path value, $Res Function(PlayerEvent_Path) _then) = _$PlayerEvent_PathCopyWithImpl;
@useResult
$Res call({
 SignalPath path
});




}
/// @nodoc
class _$PlayerEvent_PathCopyWithImpl<$Res>
    implements $PlayerEvent_PathCopyWith<$Res> {
  _$PlayerEvent_PathCopyWithImpl(this._self, this._then);

  final PlayerEvent_Path _self;
  final $Res Function(PlayerEvent_Path) _then;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(PlayerEvent_Path(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as SignalPath,
  ));
}


}

/// @nodoc


class PlayerEvent_Playing extends PlayerEvent {
  const PlayerEvent_Playing({required this.playing}): super._();
  

 final  bool playing;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayerEvent_PlayingCopyWith<PlayerEvent_Playing> get copyWith => _$PlayerEvent_PlayingCopyWithImpl<PlayerEvent_Playing>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent_Playing&&(identical(other.playing, playing) || other.playing == playing));
}


@override
int get hashCode {
    return Object.hash(runtimeType,playing);
}

@override
String toString() {
    return 'PlayerEvent.playing(playing: $playing)';
}


}

/// @nodoc
abstract mixin class $PlayerEvent_PlayingCopyWith<$Res> implements $PlayerEventCopyWith<$Res> {
  factory $PlayerEvent_PlayingCopyWith(PlayerEvent_Playing value, $Res Function(PlayerEvent_Playing) _then) = _$PlayerEvent_PlayingCopyWithImpl;
@useResult
$Res call({
 bool playing
});




}
/// @nodoc
class _$PlayerEvent_PlayingCopyWithImpl<$Res>
    implements $PlayerEvent_PlayingCopyWith<$Res> {
  _$PlayerEvent_PlayingCopyWithImpl(this._self, this._then);

  final PlayerEvent_Playing _self;
  final $Res Function(PlayerEvent_Playing) _then;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? playing = null,}) {
  return _then(PlayerEvent_Playing(
playing: null == playing ? _self.playing : playing // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class PlayerEvent_Position extends PlayerEvent {
  const PlayerEvent_Position({required this.secs}): super._();
  

 final  double secs;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayerEvent_PositionCopyWith<PlayerEvent_Position> get copyWith => _$PlayerEvent_PositionCopyWithImpl<PlayerEvent_Position>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent_Position&&(identical(other.secs, secs) || other.secs == secs));
}


@override
int get hashCode {
    return Object.hash(runtimeType,secs);
}

@override
String toString() {
    return 'PlayerEvent.position(secs: $secs)';
}


}

/// @nodoc
abstract mixin class $PlayerEvent_PositionCopyWith<$Res> implements $PlayerEventCopyWith<$Res> {
  factory $PlayerEvent_PositionCopyWith(PlayerEvent_Position value, $Res Function(PlayerEvent_Position) _then) = _$PlayerEvent_PositionCopyWithImpl;
@useResult
$Res call({
 double secs
});




}
/// @nodoc
class _$PlayerEvent_PositionCopyWithImpl<$Res>
    implements $PlayerEvent_PositionCopyWith<$Res> {
  _$PlayerEvent_PositionCopyWithImpl(this._self, this._then);

  final PlayerEvent_Position _self;
  final $Res Function(PlayerEvent_Position) _then;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? secs = null,}) {
  return _then(PlayerEvent_Position(
secs: null == secs ? _self.secs : secs // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class PlayerEvent_Ended extends PlayerEvent {
  const PlayerEvent_Ended(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent_Ended);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'PlayerEvent.ended()';
}


}




/// @nodoc


class PlayerEvent_Error extends PlayerEvent {
  const PlayerEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayerEvent_ErrorCopyWith<PlayerEvent_Error> get copyWith => _$PlayerEvent_ErrorCopyWithImpl<PlayerEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayerEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message);
}

@override
String toString() {
    return 'PlayerEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $PlayerEvent_ErrorCopyWith<$Res> implements $PlayerEventCopyWith<$Res> {
  factory $PlayerEvent_ErrorCopyWith(PlayerEvent_Error value, $Res Function(PlayerEvent_Error) _then) = _$PlayerEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$PlayerEvent_ErrorCopyWithImpl<$Res>
    implements $PlayerEvent_ErrorCopyWith<$Res> {
  _$PlayerEvent_ErrorCopyWithImpl(this._self, this._then);

  final PlayerEvent_Error _self;
  final $Res Function(PlayerEvent_Error) _then;

/// Create a copy of PlayerEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(PlayerEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
