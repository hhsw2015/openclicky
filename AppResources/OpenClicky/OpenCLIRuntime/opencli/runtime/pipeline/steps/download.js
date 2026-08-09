// Replaced by Everywhere — the upstream download step depends on
// download/index.js which pulls node:stream / external CLIs that the
// embedded runtime doesn't ship. Adapters that trigger this step get
// a structured error rather than a cryptic missing-module crash.
import { CliError } from '../../errors.js';

export async function stepDownload(_page, _params, _data, _args) {
    throw new CliError('NOT_SUPPORTED', 'pipeline.download is not implemented in the embedded runtime; use opencli list/run on a host with the full @jackwener/opencli CLI');
}
