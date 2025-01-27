import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'package:sounds_common/src/util/downloader.dart';
import 'package:sounds_common/src/util/file_util.dart';
import 'package:sounds_common/src/util/log.dart';

import '../playback_disposition.dart';
import '../track.dart';
import '../util/temp_media_file.dart';
import 'media_format.dart';

/// Provide a set of tools to manage audio data.
/// Used for Tracks and Recording.
/// This class is NOT part of the public api.
class Audio {
  final List<TempMediaFile> _tempMediaFiles = [];

  final TrackStorageType _storageType;

  ///
  MediaFormat? mediaFormat;

  /// An Audio instance can be created as one of :
  ///  * url
  ///  * path
  ///  * data buffer.
  ///
  String? url;

  ///
  String? path;

  ///
  Uint8List? _dataBuffer;

  /// During process of an audio file it may need to pass
  /// through multiple temporary files for processing.
  /// If that occurs this path points the final temporary file.
  /// [_storagePath] will have a value of [_onDisk] is true.
  String? _storagePath;

  /// Indicates if the audio media is stored on disk
  bool _onDisk = false;

  /// Indicates that [prepareStream] has been called and the stream
  /// is ready to play. Used to stop unnecessary calls to [prepareStream].
  bool _prepared = false;

  /// [true] if the audio is stored in the file system.
  /// This can be because it was passed as a path
  /// or because we had to force it to disk for code conversion
  /// or similar operations.
  /// Currently buffered data is always forced to disk.
  bool get onDisk => _onDisk;

  /// returns the length of the audio in bytes
  int get length {
    if (_onDisk) return File(_storagePath!).lengthSync();
    if (isBuffer) return _dataBuffer!.length;
    if (isFile) return File(path!).lengthSync();

    // if its a URL an asset and its not [_onDisk] then we don't
    // know its length.
    return 0;
  }

  /// Converts the underlying storage into a buffer.
  /// This may take a significant amount of time if the
  /// storage is a remote url.
  /// Once called the audio will be cached so subsequent calls
  /// will return immediately.
  Future<Uint8List> get asBuffer async {
    if (isBuffer || _dataBuffer != null) {
      return _dataBuffer!;
    }

    if (isFile) {
      _dataBuffer = await FileUtil().readIntoBuffer(_storagePath!);
    }

    if (isURL) {
      var tempMediaFile = TempMediaFile.empty();
      try {
        await Downloader.download(url!, tempMediaFile.path,
            progress: (disposition) {});

        _dataBuffer = await FileUtil().readIntoBuffer(tempMediaFile.path);
      } finally {
        tempMediaFile.delete();
      }
    }
    return _dataBuffer!;
  }

  /// Returns the location of the audio media on disk.
  String get storagePath {
    assert(_onDisk);
    return _storagePath!;
  }

  /// Caches the duration so that we don't have to calculate
  /// it each time [duration] is called.
  Duration? _duration;

  /// Returns the duration of the audio managed by this instances
  ///
  /// The duration is only available if the media is stored on disk.
  ///
  /// This is an expensive operation as we have to process the audio
  /// to determine its length.
  ///
  /// Assets, Buffers and URL based media will return a zero length
  /// duration until the first time it plays and the media is prepared.
  ///
  /// After the first call we cache the duration so responses are
  /// instant.
  //ignore: avoid_setters_without_getters
  Future<Duration> get duration async {
    if (_duration == null) {
      _duration = Duration.zero;

      var storagePath = _storagePath;
      if (_onDisk && FileUtil().fileLength(storagePath!) > 0 && mediaFormat != null) {
        _duration = await mediaFormat!.getDuration(_storagePath!);
      }
    }
    return _duration!;
  }

  //ignore: use_setters_to_change_properties
  /// This method should ONLY be used by the SoundRecorder
  /// to update a tracks duration as we record into the track.
  /// The duration is normally calculated when the [duration] getter is called.
  void setDuration(Duration duration) {
    _duration = duration;
  }

  ///
  Audio.fromFile(this.path, this.mediaFormat)
      : _storageType = TrackStorageType.file,
        _storagePath = path,
        _duration = Duration.zero,
        _dataBuffer = Uint8List(0),
        _onDisk = true;

  /// Create an [Audio] based on a flutter asset.
  /// [path] to the asset. This is normally of the form
  /// asset/xxx.wav
  Audio.fromAsset(this.path, this.mediaFormat)
      : _storageType = TrackStorageType.asset,
        _dataBuffer = null,
        _onDisk = false;

  ///
  Audio.fromURL(this.url, this.mediaFormat)
      : _storageType = TrackStorageType.url;

  /// Throws [MediaFormatNotSupportedException] if the databuffer is
  /// encoded in a unsupported media format.
  Audio.fromBuffer(Uint8List _dataBuffer, this.mediaFormat)
      : _dataBuffer = _dataBuffer,
        _storageType = TrackStorageType.buffer;

  /// returns true if the Audio's media is located in via
  /// a file Path.
  bool get isFile => _storageType == TrackStorageType.file;

  /// returns true if the Audio's media is located in via
  /// a URL
  bool get isURL => _storageType == TrackStorageType.url;

  /// true if the audio is stored in an asset.
  bool get isAsset => _storageType == TrackStorageType.asset;

  /// returns true if the Audio's media is located in a
  /// databuffer  (as opposed to a URI)
  bool get isBuffer => _storageType == TrackStorageType.buffer;

  /// returns the databuffer if there is one.
  /// see [isBuffer] to check if the audio is in a data buffer.
  Uint8List? get buffer => _dataBuffer;

  /// Does any preparatory work required on a stream before it can be played.
  /// This includes converting databuffers to paths and
  /// any re-encoding required.
  ///
  /// This method can be called multiple times and will only
  /// do the conversions once.
  Future prepareStream(LoadingProgress loadingProgress) async {
    if (_prepared) {
      return;
    }
    // each stage reports a progress value between 0.0 and 1.0.
    // If we are running multiple stages we need to divide that value
    // by the no. of stages so progress is spread across all of the
    // stages.
    var stages = 1;
    var stage = 1;

    /// we can do no preparation for the url.
    if (isURL) {
      await _downloadURL((disposition) {
        _forwardStagedProgress(loadingProgress, disposition, stage, stages);
      });
      stage++;
    }

    if (isAsset) {
      await _loadAsset();
    }

    // android doesn't support data buffers so we must convert
    // to a file.
    // iOS doesn't support opus so we must convert to a file so we
    /// remux it.
    if ((Platform.isAndroid && isBuffer) || isAsset) {
      _writeBufferToDisk((disposition) {
        _forwardStagedProgress(loadingProgress, disposition, stage, stages);
      });
      stage++;
    }

    _prepared = true;
  }

  Future<void> _downloadURL(LoadingProgress progress) async {
    var saveToFile = TempMediaFile.empty();
    _tempMediaFiles.add(saveToFile);
    await Downloader.download(url!, saveToFile.path, progress: progress);
    _storagePath = saveToFile.path;
    _onDisk = true;
  }

  Future<void> _loadAsset() async {
    Log.d('loadingAsset');
    _dataBuffer = (await rootBundle.load(path!)).buffer.asUint8List();
  }

  /// Only writes the audio to disk if we have a databuffer and we haven't
  /// already written it to disk.
  ///
  /// Returns the path where the current version of the audio is stored.
  void _writeBufferToDisk(LoadingProgress progress) {
    if (!_onDisk && (isBuffer || isAsset)) {
      var tempMediaFile = TempMediaFile.fromBuffer(_dataBuffer!, progress);
      _tempMediaFiles.add(tempMediaFile);

      /// update the path to the new file.
      _storagePath = tempMediaFile.path;
      _onDisk = true;
    }
  }

  /// delete any tempoary media files we created whilst recording.
  void _deleteTempFiles() {
    for (var tmp in _tempMediaFiles) {
      tmp.delete();
    }
    _tempMediaFiles.clear();
  }

  /// You MUST call release once you have finished with an [Audio]
  /// otherwise you will leak temp files.
  void release() {
    if (_tempMediaFiles.isNotEmpty) {
      _prepared = false;
      _onDisk = false;
      _deleteTempFiles();
    }
  }

  /// Adjust the loading progress as we have multiple stages we go
  /// through when preparing a stream.
  void _forwardStagedProgress(LoadingProgress loadingProgress,
      PlaybackDisposition disposition, int stage, int stages) {
    var rewritten = false;

    if (disposition.state == PlaybackDispositionState.loading) {
      // if we have 3 stages then a progress of 1.0 becomes progress
      /// 0.3.
      var progress = disposition.progress / stages;
      // offset the progress based on which stage we are in.
      progress += 1.0 / stages * (stage - 1);
      loadingProgress(PlaybackDisposition.loading(progress: progress));
      rewritten = true;
    }

    if (disposition.state == PlaybackDispositionState.loaded) {
      if (stage != stages) {
        /// if we are not the last stage change 'loaded' into loading.
        loadingProgress(
            PlaybackDisposition.loading(progress: stage * (1.0 / stages)));
        rewritten = true;
      }
    }
    if (!rewritten) {
      loadingProgress(disposition);
    }
  }

  @override
  String toString() {
    var desc = 'MediaFormat: ${mediaFormat?.name ?? "NONE"}';
    if (_onDisk) {
      desc += 'storage: $_storagePath';
    }

    if (isURL) desc += ' url: $url';
    if (isFile) desc += ' path: $path';
    if (isBuffer) desc += ' buffer len: ${_dataBuffer!.length}';
    if (isAsset) desc += ' asset: $path';

    return desc;
  }
}
