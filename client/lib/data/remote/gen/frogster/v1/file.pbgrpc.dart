// This is a generated file - do not edit.
//
// Generated from frogster/v1/file.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'file.pb.dart' as $0;

export 'file.pb.dart';

/// FileTransfer moves encrypted attachments.
///
/// Every byte that reaches this service is already ciphertext: the client
/// encrypts a file with a fresh AES-256-GCM key before the first chunk is sent,
/// and delivers that key to recipients inside the Double Ratchet payload of the
/// chat message. The server therefore stores blobs it cannot read and never
/// learns the file's type, name, or contents.
///
/// Streaming rather than a single request keeps memory flat: a 100 MiB upload
/// costs one chunk buffer, not 100 MiB, on both client and server.
@$pb.GrpcServiceName('frogster.v1.FileTransfer')
class FileTransferClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  FileTransferClient(super.channel, {super.options, super.interceptors});

  /// Upload streams an encrypted blob and returns its id.
  $grpc.ResponseFuture<$0.UploadResponse> upload(
    $async.Stream<$0.UploadRequest> request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(_$upload, request, options: options).single;
  }

  /// Download streams an encrypted blob back.
  $grpc.ResponseStream<$0.DownloadChunk> download(
    $0.DownloadRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$download, $async.Stream.fromIterable([request]),
        options: options);
  }

  /// Delete removes a blob the caller uploaded.
  $grpc.ResponseFuture<$0.DeleteResponse> delete(
    $0.DeleteRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$delete, request, options: options);
  }

  // method descriptors

  static final _$upload =
      $grpc.ClientMethod<$0.UploadRequest, $0.UploadResponse>(
          '/frogster.v1.FileTransfer/Upload',
          ($0.UploadRequest value) => value.writeToBuffer(),
          $0.UploadResponse.fromBuffer);
  static final _$download =
      $grpc.ClientMethod<$0.DownloadRequest, $0.DownloadChunk>(
          '/frogster.v1.FileTransfer/Download',
          ($0.DownloadRequest value) => value.writeToBuffer(),
          $0.DownloadChunk.fromBuffer);
  static final _$delete =
      $grpc.ClientMethod<$0.DeleteRequest, $0.DeleteResponse>(
          '/frogster.v1.FileTransfer/Delete',
          ($0.DeleteRequest value) => value.writeToBuffer(),
          $0.DeleteResponse.fromBuffer);
}

@$pb.GrpcServiceName('frogster.v1.FileTransfer')
abstract class FileTransferServiceBase extends $grpc.Service {
  $core.String get $name => 'frogster.v1.FileTransfer';

  FileTransferServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.UploadRequest, $0.UploadResponse>(
        'Upload',
        upload,
        true,
        false,
        ($core.List<$core.int> value) => $0.UploadRequest.fromBuffer(value),
        ($0.UploadResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DownloadRequest, $0.DownloadChunk>(
        'Download',
        download_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.DownloadRequest.fromBuffer(value),
        ($0.DownloadChunk value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.DeleteRequest, $0.DeleteResponse>(
        'Delete',
        delete_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.DeleteRequest.fromBuffer(value),
        ($0.DeleteResponse value) => value.writeToBuffer()));
  }

  $async.Future<$0.UploadResponse> upload(
      $grpc.ServiceCall call, $async.Stream<$0.UploadRequest> request);

  $async.Stream<$0.DownloadChunk> download_Pre($grpc.ServiceCall $call,
      $async.Future<$0.DownloadRequest> $request) async* {
    yield* download($call, await $request);
  }

  $async.Stream<$0.DownloadChunk> download(
      $grpc.ServiceCall call, $0.DownloadRequest request);

  $async.Future<$0.DeleteResponse> delete_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.DeleteRequest> $request) async {
    return delete($call, await $request);
  }

  $async.Future<$0.DeleteResponse> delete(
      $grpc.ServiceCall call, $0.DeleteRequest request);
}
