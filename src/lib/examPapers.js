import { supabase } from './supabase'

export const EXAM_PAPER_BUCKET = 'exam-question-papers'
export const MAX_EXAM_PAPER_BYTES = 20 * 1024 * 1024

export function formatFileSize(bytes = 0) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export async function validatePdf(file) {
  if (!file) throw new Error('Choose a PDF file first.')
  if (file.size > MAX_EXAM_PAPER_BYTES) throw new Error('PDF must be 20 MB or smaller.')
  if (!file.name.toLowerCase().endsWith('.pdf')) throw new Error('Choose a file with a .pdf extension.')
  const signature = await file.slice(0, 5).text()
  if (signature !== '%PDF-') throw new Error('This file does not have a valid PDF signature.')
  return file
}

export async function createExamPaperSignedUrl(path, expiresIn = 600) {
  const { data, error } = await supabase.storage.from(EXAM_PAPER_BUCKET).createSignedUrl(path, expiresIn)
  if (error) throw error
  return data.signedUrl
}

// Supabase's standard upload call does not expose byte-level progress. Use its
// authenticated Storage REST endpoint with the user's session token and anon key.
export async function uploadExamPaper(file, path, onProgress = () => {}) {
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  if (sessionError) throw sessionError
  if (!session?.access_token) throw new Error('Your session expired. Sign in again and retry the upload.')

  const baseUrl = import.meta.env.VITE_SUPABASE_URL?.replace(/\/$/, '')
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY
  if (!baseUrl || !anonKey) throw new Error('Supabase Storage is not configured.')

  const encodedPath = path.split('/').map(encodeURIComponent).join('/')
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest()
    request.open('POST', `${baseUrl}/storage/v1/object/${EXAM_PAPER_BUCKET}/${encodedPath}`)
    request.setRequestHeader('apikey', anonKey)
    request.setRequestHeader('Authorization', `Bearer ${session.access_token}`)
    request.setRequestHeader('Content-Type', 'application/pdf')
    request.upload.onprogress = event => {
      if (event.lengthComputable) onProgress(Math.round((event.loaded / event.total) * 100))
    }
    request.onerror = () => reject(new Error('Network error while uploading the PDF.'))
    request.onabort = () => reject(new Error('PDF upload was cancelled.'))
    request.onload = () => {
      if (request.status >= 200 && request.status < 300) {
        onProgress(100)
        resolve()
        return
      }
      let message = `PDF upload failed (${request.status}).`
      try { message = JSON.parse(request.responseText)?.message || message } catch { /* use fallback */ }
      reject(new Error(message))
    }
    request.send(file)
  })
}

export async function removeExamPaper(path) {
  if (!path) return
  const { error } = await supabase.storage.from(EXAM_PAPER_BUCKET).remove([path])
  if (error) throw error
}
