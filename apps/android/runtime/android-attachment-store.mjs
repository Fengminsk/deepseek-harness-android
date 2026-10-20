import { LocalAttachmentStore } from '@deepseek-ai/dsh-attachment-local'
import { publishImmutableFile } from './immutable-file-publisher.mjs'

/** Retain DSH references, hashing and durability; Android supplies exclusive publication. */
export default class AndroidAttachmentStore extends LocalAttachmentStore {
  publishImmutableFile = publishImmutableFile
}
