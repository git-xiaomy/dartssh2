import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/src/sftp/sftp_client.dart';
import 'package:dartssh2/src/utils/stream.dart';

/// The amount of data to send in a single SFTP packet.
///
/// From the SFTP spec it's safe to send up to 32KB of data in a single packet.
/// To strike a balance between capability and performance, we choose 16KB.
const chunkSize = 16 * 1024;

/// The maximum amount of data that can be sent to the remote host without
/// receiving an acknowledgement.
const maxBytesOnTheWire = chunkSize * 64;

/// Holds the state of a streaming write operation from [stream] to [file].
class SftpFileWriter{
  /// The remote file to write to.
  final SftpFile file;

  /// The stream of data to write to [file].
  final Stream<Uint8List> stream;

  /// The offset in [file] to start writing to.
  final int offset;

  /// Called when [bytes] of data have been successfully written to [file].
  final Function(int bytes)? onProgress;

  /// 是否暂停的标志位
  bool pauseFlag = false;

  /// Creates a new [SftpFileWriter]. The upload process is started immediately
  /// after construction.
  SftpFileWriter(this.file, this.stream, this.offset, this.onProgress) {
    _subscription =
        stream.transform(MaxChunkSize(chunkSize)).listen(_handleLocalData);
    _subscription.onDone(_handleLocalDone);
  }

  /// The subscription for [stream]. We use this to pause and resume the data
  /// source.
  late final StreamSubscription<Uint8List> _subscription;

  final _doneCompleter = Completer<void>();

  /// Bytes of data that have been sent to the remote host.
  var _bytesSent = 0;

  /// Bytes of data that have been acknowledged by the remote host.
  var _bytesAcked = 0;

  /// Number of bytes sent to the server but not yet acknowledged.
  ///
  /// This number is used to pause the stream when it gets too high.
  int get _bytesOnTheWire => _bytesSent - _bytesAcked;

  /// Whether [stream] has emitted all of its data.
  var _streamDone = false;

  /// A [Future] that completes when:
  ///
  /// - All data from [stream] has been written to [file]
  /// - Or the write operation has been aborted by calling [abort].
  @override
  Future<void> get done => _doneCompleter.future;

  /// The number of bytes that have been successfully written to [file].
  int get progress => _bytesAcked;

  /// Stops [stream] from emitting more data. Returns a [Future] that completes
  /// when the underlying data source of [stream] has been successfully closed.
  ///
  /// Calling [abort] will make [done] to complete immediately.
  Future<void> abort() async {
    pause();
    // 标记为已完成
    _doneCompleter.complete();
    // 取消流订阅
    await _subscription.cancel();
    await file.close();
  }

  /// Pauses [stream] from emitting more data. It's safe to call this even if
  /// the stream is already paused. Use [resume] to resume the operation.
  void pause() {
    pauseFlag = true;
    if (!_subscription.isPaused) {
      _subscription.pause();
    }
  }

  /// Resumes [stream] after it has been paused. It's safe to call this even if
  /// the stream is not paused. Use [pause] to pause the operation.
  void resume() {
    pauseFlag = false;
    _subscription.resume();
  }

  /// Handles the incoming data chunks from the stream.
  ///
  /// This function manages the flow control by pausing the stream if the
  /// amount of unacknowledged data (`_bytesOnTheWire`) exceeds the
  /// `maxBytesOnTheWire` limit. It then writes the data chunk to the remote file
  /// at the appropriate offset, updates the counters, and triggers the
  /// progress callback. Finally, it checks if all data has been acknowledged
  /// and completes the operation if done.
  Future<void> _handleLocalData(Uint8List chunk) async {
    if (_bytesOnTheWire >= maxBytesOnTheWire) {
      _subscription.pause();
    } else {
      if(!pauseFlag){
        _subscription.resume();
      }
    }
    final chunkWriteOffset = offset + _bytesSent;
    _bytesSent += chunk.length;
    await file.writeBytes(chunk, offset: chunkWriteOffset);
    _bytesAcked += chunk.length;
    onProgress?.call(_bytesAcked);

    if (_bytesOnTheWire < maxBytesOnTheWire && !pauseFlag) {
      _subscription.resume();
    }

    if (_streamDone &&
        _bytesSent == _bytesAcked &&
        !_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  /// Handles the completion of the data stream.
  ///
  /// This function is triggered when the stream has finished emitting all its
  /// data. It checks if all data has been successfully acknowledged and
  /// marks the operation as complete by calling `_doneCompleter.complete()`
  /// if no more data remains to be processed.
  void _handleLocalDone() {
    _streamDone = true;
    if (_bytesSent == _bytesAcked) {
      _doneCompleter.complete();
    }
  }
}