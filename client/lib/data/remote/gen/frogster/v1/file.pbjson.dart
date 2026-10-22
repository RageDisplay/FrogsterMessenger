// This is a generated file - do not edit.
//
// Generated from frogster/v1/file.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use uploadRequestDescriptor instead')
const UploadRequest$json = {
  '1': 'UploadRequest',
  '2': [
    {
      '1': 'init',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.frogster.v1.UploadInit',
      '9': 0,
      '10': 'init'
    },
    {'1': 'chunk', '3': 2, '4': 1, '5': 12, '9': 0, '10': 'chunk'},
  ],
  '8': [
    {'1': 'payload'},
  ],
};

/// Descriptor for `UploadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadRequestDescriptor = $convert.base64Decode(
    'Cg1VcGxvYWRSZXF1ZXN0Ei0KBGluaXQYASABKAsyFy5mcm9nc3Rlci52MS5VcGxvYWRJbml0SA'
    'BSBGluaXQSFgoFY2h1bmsYAiABKAxIAFIFY2h1bmtCCQoHcGF5bG9hZA==');

@$core.Deprecated('Use uploadInitDescriptor instead')
const UploadInit$json = {
  '1': 'UploadInit',
  '2': [
    {'1': 'total_size', '3': 1, '4': 1, '5': 4, '10': 'totalSize'},
    {'1': 'content_hint', '3': 2, '4': 1, '5': 9, '10': 'contentHint'},
    {'1': 'digest', '3': 3, '4': 1, '5': 12, '10': 'digest'},
  ],
};

/// Descriptor for `UploadInit`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadInitDescriptor = $convert.base64Decode(
    'CgpVcGxvYWRJbml0Eh0KCnRvdGFsX3NpemUYASABKARSCXRvdGFsU2l6ZRIhCgxjb250ZW50X2'
    'hpbnQYAiABKAlSC2NvbnRlbnRIaW50EhYKBmRpZ2VzdBgDIAEoDFIGZGlnZXN0');

@$core.Deprecated('Use uploadResponseDescriptor instead')
const UploadResponse$json = {
  '1': 'UploadResponse',
  '2': [
    {'1': 'blob_id', '3': 1, '4': 1, '5': 9, '10': 'blobId'},
    {'1': 'expires_at', '3': 2, '4': 1, '5': 3, '10': 'expiresAt'},
    {'1': 'stored_size', '3': 3, '4': 1, '5': 4, '10': 'storedSize'},
  ],
};

/// Descriptor for `UploadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadResponseDescriptor = $convert.base64Decode(
    'Cg5VcGxvYWRSZXNwb25zZRIXCgdibG9iX2lkGAEgASgJUgZibG9iSWQSHQoKZXhwaXJlc19hdB'
    'gCIAEoA1IJZXhwaXJlc0F0Eh8KC3N0b3JlZF9zaXplGAMgASgEUgpzdG9yZWRTaXpl');

@$core.Deprecated('Use downloadRequestDescriptor instead')
const DownloadRequest$json = {
  '1': 'DownloadRequest',
  '2': [
    {'1': 'blob_id', '3': 1, '4': 1, '5': 9, '10': 'blobId'},
  ],
};

/// Descriptor for `DownloadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List downloadRequestDescriptor = $convert
    .base64Decode('Cg9Eb3dubG9hZFJlcXVlc3QSFwoHYmxvYl9pZBgBIAEoCVIGYmxvYklk');

@$core.Deprecated('Use downloadChunkDescriptor instead')
const DownloadChunk$json = {
  '1': 'DownloadChunk',
  '2': [
    {'1': 'chunk', '3': 1, '4': 1, '5': 12, '10': 'chunk'},
    {'1': 'offset', '3': 2, '4': 1, '5': 4, '10': 'offset'},
    {'1': 'digest', '3': 3, '4': 1, '5': 12, '10': 'digest'},
    {'1': 'total_size', '3': 4, '4': 1, '5': 4, '10': 'totalSize'},
  ],
};

/// Descriptor for `DownloadChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List downloadChunkDescriptor = $convert.base64Decode(
    'Cg1Eb3dubG9hZENodW5rEhQKBWNodW5rGAEgASgMUgVjaHVuaxIWCgZvZmZzZXQYAiABKARSBm'
    '9mZnNldBIWCgZkaWdlc3QYAyABKAxSBmRpZ2VzdBIdCgp0b3RhbF9zaXplGAQgASgEUgl0b3Rh'
    'bFNpemU=');

@$core.Deprecated('Use deleteRequestDescriptor instead')
const DeleteRequest$json = {
  '1': 'DeleteRequest',
  '2': [
    {'1': 'blob_id', '3': 1, '4': 1, '5': 9, '10': 'blobId'},
  ],
};

/// Descriptor for `DeleteRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteRequestDescriptor = $convert
    .base64Decode('Cg1EZWxldGVSZXF1ZXN0EhcKB2Jsb2JfaWQYASABKAlSBmJsb2JJZA==');

@$core.Deprecated('Use deleteResponseDescriptor instead')
const DeleteResponse$json = {
  '1': 'DeleteResponse',
  '2': [
    {'1': 'deleted', '3': 1, '4': 1, '5': 8, '10': 'deleted'},
  ],
};

/// Descriptor for `DeleteResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteResponseDescriptor = $convert
    .base64Decode('Cg5EZWxldGVSZXNwb25zZRIYCgdkZWxldGVkGAEgASgIUgdkZWxldGVk');
