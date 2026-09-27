// glTF-Transform I/O instances.

import { Logger, NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco3d from 'draco3dgltf';
import { MeshoptDecoder } from 'meshoptimizer';
import { COMPRESSION_EXTENSIONS } from './glb.mjs';

let dracoDecoder = null;

/** Full reader/writer: all extensions, meshopt and Draco decoders. */
export async function createIO() {
  await MeshoptDecoder.ready;
  dracoDecoder ??= await draco3d.createDecoderModule();
  return new NodeIO()
    .setLogger(new Logger(Logger.Verbosity.ERROR))
    .registerExtensions(ALL_EXTENSIONS)
    .registerDependencies({ 'meshopt.decoder': MeshoptDecoder, 'draco3d.decoder': dracoDecoder });
}

/**
 * "Plain" reader: knows ordinary glTF extensions (e.g. WebP textures) but has NO compression
 * decoders. Used to prove that a repaired file opens in tools without meshopt/Draco support.
 */
export function createPlainIO() {
  return new NodeIO()
    .setLogger(new Logger(Logger.Verbosity.SILENT))
    .registerExtensions(ALL_EXTENSIONS.filter((E) => !COMPRESSION_EXTENSIONS.includes(E.EXTENSION_NAME)));
}
