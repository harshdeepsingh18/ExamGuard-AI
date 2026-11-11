import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Camera, CheckCircle2, Clock3, ExternalLink, FileText, RefreshCw, ShieldAlert } from 'lucide-react'
import { FaceDetector, FilesetResolver } from '@mediapipe/tasks-vision'
import { configured, supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { createExamPaperSignedUrl, formatFileSize } from '../lib/examPapers'

const TAB_SWITCHES_ALLOWED = 2
const MONITORING_EVENT_TYPES = new Set([
  'tab_hidden',
  'window_blur',
  'camera_started',
  'camera_stopped',
  'face_absent',
  'multiple_people',
  'camera_unsupported',
  'camera_denied',
])
const MEDIAPIPE_WASM_BASE = 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.2.2/wasm'
const FACE_DETECTOR_MODEL = 'https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite'

export function ExamRoom() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { profile } = useAuth()
  const [exam, setExam] = useState(null)
  const [paper, setPaper] = useState(null)
  const [answers, setAnswers] = useState({})
  const [seconds, setSeconds] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState(null)
  const [expired, setExpired] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [submittedForTabSwitches, setSubmittedForTabSwitches] = useState(false)
  const [showPaper, setShowPaper] = useState(false)
  const [reportReason, setReportReason] = useState('')
  const [reportMessage, setReportMessage] = useState('')
  const [monitorWarnings, setMonitorWarnings] = useState(0)
  const [monitoringPending, setMonitoringPending] = useState(0)
  const [monitoringStorageWarning, setMonitoringStorageWarning] = useState('')
  const [tabSwitches, setTabSwitches] = useState(0)
  const [savedTabSwitches, setSavedTabSwitches] = useState(0)
  const [cameraPermissionStatus, setCameraPermissionStatus] = useState('Not requested')
  const [cameraStreamStatus, setCameraStreamStatus] = useState('Camera permission required')
  const [faceDetectionStatus, setFaceDetectionStatus] = useState('Not started')
  const [cameraStream, setCameraStream] = useState(null)
  const videoRef = useRef(null)
  const cameraStreamRef = useRef(null)
  const cameraRequestRef = useRef(false)
  const [videoElement, setVideoElement] = useState(null)
  const lastEventRef = useRef({})
  const eventQueueRef = useRef([])
  const flushingEventsRef = useRef(null)
  const flushMonitoringEventsRef = useRef(null)
  const restoredQueueKeyRef = useRef('')
  const monitoringActiveRef = useRef(false)
  const componentActiveRef = useRef(true)
  const tabSwitchCountRef = useRef(0)
  const eventStorageKey = exam?.attempt_id && profile?.id
    ? `examguard-monitor-events:${profile.id}:${exam.attempt_id}`
    : ''
  const timerActive = seconds !== null && !result && !expired && !submitted
  const monitoringActive = timerActive && !busy && Boolean(
    configured && exam?.attempt_id
      && exam.exam.monitoring_enabled
      && profile?.id,
  )
  monitoringActiveRef.current = monitoringActive

  useEffect(() => {
    componentActiveRef.current = true
    return () => { componentActiveRef.current = false }
  }, [])

  useEffect(() => {
    if (!exam?.attempt_id) return
    tabSwitchCountRef.current = 0
    lastEventRef.current = {}
    eventQueueRef.current = []
    setTabSwitches(0)
    setSavedTabSwitches(0)
    setMonitorWarnings(0)
    setMonitoringPending(0)
  }, [exam?.attempt_id])

  const activateExam = useCallback(async (paperData, isActive = () => true) => {
    setError('')
    setLoading(true)
    const { data, error: startError } = await supabase.rpc('start_exam', { p_exam: id })
    if (!isActive()) return false
    if (startError) {
      setError(startError.message)
      setLoading(false)
      return false
    }

    setExam(data)
    setPaper(paperData)
    setAnswers(Object.fromEntries((data.saved_answers || []).map(answer => [answer.question_id, answer.answer_text ?? answer.selected_answer])))
    const elapsed = Math.floor((Date.now() - new Date(data.attempt_started_at).getTime()) / 1000)
    setSeconds(Math.max(0, data.exam.duration_minutes * 60 - elapsed))
    setLoading(false)
    return true
  }, [id])

  useEffect(() => {
    if (!configured) { setError('Connect Supabase before starting an exam.'); setLoading(false); return }
    let active = true
    const openExam = async () => {
      const { data: paperData, error: paperError } = await supabase.from('exams')
        .select('exam_type,pdf_storage_path,pdf_filename,pdf_size_bytes,pdf_enabled,camera_required')
        .eq('id', id).single()
      if (!active) return
      if (paperError) {
        setError(paperError.message)
        setLoading(false)
        return
      }
      if (paperData.camera_required) {
        setPaper(paperData)
        setLoading(false)
        return
      }
      await activateExam(paperData, () => active)
    }
    openExam()
    return () => { active = false }
  }, [id, activateExam])

  const setVideoRef = useCallback(element => {
    videoRef.current = element
    if (element) setVideoElement(current => current === element ? current : element)
  }, [])

  const waitForVideoPlayback = useCallback(async (stream, video = videoRef.current) => {
    if (!video) throw new Error('The local camera preview is unavailable.')
    const track = stream.getVideoTracks()[0]
    if (!track || track.readyState !== 'live' || !stream.active) {
      throw new Error('The camera stream is not active.')
    }

    if (video.srcObject !== stream) video.srcObject = stream

    const waitForCondition = (condition, events, timeoutMessage) => new Promise((resolve, reject) => {
      let timeout
      const cleanup = () => {
        clearTimeout(timeout)
        events.forEach(eventName => video.removeEventListener(eventName, check))
        video.removeEventListener('error', onError)
        track.removeEventListener('ended', onTrackEnded)
      }
      const finish = callback => value => {
        cleanup()
        callback(value)
      }
      const onError = finish(() => reject(new Error(
        video.error?.message || 'The camera preview could not start.',
      )))
      const onTrackEnded = finish(() => reject(new Error('The camera disconnected during startup.')))
      const check = () => {
        if (video.error) {
          onError()
          return
        }
        if (track.readyState !== 'live' || !stream.active) {
          onTrackEnded()
          return
        }
        if (condition()) finish(resolve)()
      }
      events.forEach(eventName => video.addEventListener(eventName, check))
      video.addEventListener('error', onError, { once: true })
      track.addEventListener('ended', onTrackEnded, { once: true })
      timeout = setTimeout(finish(() => reject(new Error(timeoutMessage))), 10000)
      check()
    })

    try {
      if (video.readyState < HTMLMediaElement.HAVE_METADATA) {
        await waitForCondition(
          () => video.readyState >= HTMLMediaElement.HAVE_METADATA,
          ['loadedmetadata'],
          'Timed out waiting for camera video metadata.',
        )
      }
      await video.play()
      await waitForCondition(
        () => !video.paused
          && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
          && video.videoWidth > 0
          && video.videoHeight > 0,
        ['playing', 'loadeddata', 'canplay', 'timeupdate'],
        'Timed out waiting for a decoded camera frame.',
      )
      if (typeof video.requestVideoFrameCallback === 'function') {
        await new Promise((resolve, reject) => {
          let timeout
          let callbackId
          const cleanup = () => {
            clearTimeout(timeout)
            if (callbackId !== undefined && typeof video.cancelVideoFrameCallback === 'function') {
              video.cancelVideoFrameCallback(callbackId)
            }
            track.removeEventListener('ended', onTrackEnded)
          }
          const onFrame = () => {
            cleanup()
            if (track.readyState === 'live' && stream.active && !video.paused) resolve()
            else reject(new Error('The camera stopped before its first video frame.'))
          }
          const onTrackEnded = () => {
            cleanup()
            reject(new Error('The camera disconnected before its first video frame.'))
          }
          timeout = setTimeout(() => {
            cleanup()
            reject(new Error('Timed out waiting for the first camera frame.'))
          }, 5000)
          track.addEventListener('ended', onTrackEnded, { once: true })
          callbackId = video.requestVideoFrameCallback(onFrame)
        })
      }
    } catch (playError) {
      if (playError.name === 'NotAllowedError') {
        throw new Error('Browser playback was blocked. Allow camera playback and retry.')
      }
      throw playError
    }

    if (track.readyState !== 'live' || !stream.active || video.paused
      || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA
      || video.videoWidth === 0 || video.videoHeight === 0) {
      throw new Error('The camera stopped before video playback was verified.')
    }
  }, [])

  const requestCamera = useCallback(async () => {
    if (cameraRequestRef.current) return null
    if (cameraStreamRef.current?.active
      && cameraStreamRef.current.getVideoTracks().some(track => track.readyState === 'live')) {
      cameraRequestRef.current = true
      const existingStream = cameraStreamRef.current
      setCameraStreamStatus('Verifying camera preview')
      try {
        await waitForVideoPlayback(existingStream)
        setCameraStreamStatus('Camera active · video playing')
        return existingStream
      } catch (cameraError) {
        setCameraStreamStatus('Camera playback failed')
        setError(`Camera preview could not be verified. ${cameraError.message || 'Video playback failed.'}`)
        throw cameraError
      } finally {
        cameraRequestRef.current = false
      }
    }
    if (cameraStreamRef.current) {
      cameraStreamRef.current.getTracks().forEach(track => track.stop())
      cameraStreamRef.current = null
      setCameraStream(null)
    }

    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraStreamStatus('Camera initialization failed · unsupported browser')
      throw new Error('This browser does not support camera access through MediaDevices.')
    }

    cameraRequestRef.current = true
    setError('')
    setCameraPermissionStatus('Requesting permission')
    setCameraStreamStatus('Requesting camera permission')
    setFaceDetectionStatus('Not started')
    let stream
    let permissionGranted = false
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false })
      if (!componentActiveRef.current) {
        stream.getTracks().forEach(track => track.stop())
        return null
      }
      cameraStreamRef.current = stream
      permissionGranted = true
      setCameraPermissionStatus('Granted')
      setCameraStreamStatus('Camera initializing')
      await waitForVideoPlayback(stream)
      if (!componentActiveRef.current) {
        stream.getTracks().forEach(track => track.stop())
        return null
      }
      cameraStreamRef.current = stream
      setCameraStream(stream)
      setCameraStreamStatus('Camera active · video playing')
      return stream
    } catch (cameraError) {
      stream?.getTracks().forEach(track => track.stop())
      cameraStreamRef.current = null
      setCameraStream(null)
      setFaceDetectionStatus('Not started')
      if (cameraError.name === 'NotAllowedError' || cameraError.name === 'SecurityError') {
        if (!permissionGranted) setCameraPermissionStatus('Denied')
        setCameraStreamStatus('Camera permission denied')
        setError(`Camera permission was denied. ${cameraError.message || ''}`.trim())
      } else if (cameraError.name === 'NotFoundError' || cameraError.name === 'DevicesNotFoundError') {
        setCameraPermissionStatus('Unavailable')
        setCameraStreamStatus('No camera device available')
        setError('No camera device is available. Connect a camera and retry.')
      } else if (cameraError.message?.includes('disconnected') || cameraError.message?.includes('stopped')) {
        setCameraStreamStatus('Camera disconnected')
        setError(`The camera disconnected during startup. ${cameraError.message}`)
      } else if (cameraError.message?.includes('playback') || cameraError.message?.includes('decoded')
        || cameraError.message?.includes('video frame') || cameraError.message?.includes('metadata')) {
        setCameraStreamStatus('Camera playback failed')
        setError(`Camera playback could not be verified. ${cameraError.message}`)
      } else {
        setCameraStreamStatus('Camera initialization failed')
        setError(`Camera could not be initialized. ${cameraError.message || 'Check browser and device permissions.'}`)
      }
      throw cameraError
    } finally {
      cameraRequestRef.current = false
    }
  }, [waitForVideoPlayback])

  const startRequiredCamera = async () => {
    try {
      const stream = await requestCamera()
      if (!stream) return
      const started = await activateExam(paper, () => componentActiveRef.current)
      if (!started) {
        stream.getTracks().forEach(track => track.stop())
        cameraStreamRef.current = null
        if (componentActiveRef.current) {
          setCameraStream(null)
          setCameraStreamStatus('Camera permission required')
        }
      }
    } catch {
      if (componentActiveRef.current) setFaceDetectionStatus('Not started')
    }
  }

  const submit = useCallback(async (confirmPdf = true) => {
    if (busy || expired || submitted || !exam || !configured) return
    if (paper?.exam_type === 'pdf' && confirmPdf && !confirm('Finish and submit this PDF exam?')) return
    if (monitoringActiveRef.current && eventQueueRef.current.length) {
      await flushMonitoringEventsRef.current?.()
    }
    setBusy(true)
    const p_answers = Object.entries(answers).map(([question_id, answer]) => typeof answer === 'number' ? ({ question_id, selected_answer: answer }) : ({ question_id, answer_text: answer }))
    const { data, error: submitError } = await supabase.rpc('submit_exam', { p_attempt: exam.attempt_id, p_answers })
    setBusy(false)
    if (submitError) setError(submitError.message)
    else if (data?.expired) setExpired(true)
    else if (data?.pdf_only) setSubmitted(true)
    else setResult(data)
  }, [answers, busy, expired, exam, paper?.exam_type, submitted])

  useEffect(() => {
    if (!exam || paper?.exam_type === 'pdf' || !Object.keys(answers).length || result || expired || submitted || !configured) return
    const timer = setTimeout(() => {
      const p_answers = Object.entries(answers).map(([question_id, answer]) => typeof answer === 'number' ? ({ question_id, selected_answer: answer }) : ({ question_id, answer_text: answer }))
      supabase.rpc('save_exam_answers', { p_attempt: exam.attempt_id, p_answers }).then(({ error: saveError }) => {
        if (saveError) setError(saveError.message)
      })
    }, 350)
    return () => clearTimeout(timer)
  }, [answers, exam, expired, paper?.exam_type, result, submitted])

  useEffect(() => {
    if (!timerActive) return
    const timer = setInterval(() => setSeconds(value => value <= 1 ? 0 : value - 1), 1000)
    return () => clearInterval(timer)
  }, [timerActive])

  const persistEventQueue = useCallback(queue => {
    if (!eventStorageKey) return false
    try {
      if (queue.length) sessionStorage.setItem(eventStorageKey, JSON.stringify(queue))
      else sessionStorage.removeItem(eventStorageKey)
      return true
    } catch (storageError) {
      setMonitoringStorageWarning(`Pending events may not survive a page reload: ${storageError.message}`)
      return false
    }
  }, [eventStorageKey])

  const flushMonitoringEvents = useCallback(() => {
    if (!eventStorageKey) return Promise.resolve(false)
    if (flushingEventsRef.current) {
      return flushingEventsRef.current.then(saved =>
        saved && eventQueueRef.current.length ? flushMonitoringEvents() : saved,
      )
    }

    const flushPromise = (async () => {
      while (eventQueueRef.current.length) {
        const event = eventQueueRef.current[0]
        let eventError = null
        let saved = false
        for (let attempt = 0; attempt < 3; attempt += 1) {
          try {
            const { error } = await supabase.from('exam_monitoring_events').insert(event)
            if (!error || error.code === '23505') {
              saved = true
              break
            }
            eventError = error
          } catch (error) {
            eventError = error
          }

          const retryable = eventError instanceof TypeError
            || eventError?.status === 0
            || eventError?.status === 429
            || eventError?.status >= 500
          if (!retryable || attempt === 2) break
          await new Promise(resolve => setTimeout(resolve, 500 * (2 ** attempt)))
        }

        if (!saved) {
          setMonitoringPending(eventQueueRef.current.length)
          if (eventError) setError(`Monitoring event could not be saved: ${eventError.message || 'Temporary network error.'}`)
          persistEventQueue(eventQueueRef.current)
          return false
        }

        eventQueueRef.current.shift()
        persistEventQueue(eventQueueRef.current)
        setMonitoringPending(eventQueueRef.current.length)
        setMonitorWarnings(value => value + 1)
        if (event.event_type === 'tab_hidden') setSavedTabSwitches(value => value + 1)
        setError(current =>
          current.startsWith('Monitoring event could not be saved:') ? '' : current,
        )
      }
      return true
    })()
    flushingEventsRef.current = flushPromise
    void flushPromise.then(() => {
      if (flushingEventsRef.current === flushPromise) flushingEventsRef.current = null
    }, () => {
      if (flushingEventsRef.current === flushPromise) flushingEventsRef.current = null
    })
    return flushPromise
  }, [eventStorageKey, persistEventQueue])
  flushMonitoringEventsRef.current = flushMonitoringEvents

  const recordMonitoringEvent = useCallback((eventType, metadata = {}) => {
    if (!monitoringActive || !monitoringActiveRef.current) return
    const now = Date.now()
    if (eventType !== 'tab_hidden' && now - (lastEventRef.current[eventType] || 0) < 4000) return

    const eventId = globalThis.crypto?.randomUUID?.()
    if (!eventId) {
      setError('Monitoring event could not be saved: secure event IDs are unavailable in this browser.')
      return
    }

    const event = {
      id: eventId,
      attempt_id: exam.attempt_id,
      student_id: profile.id,
      event_type: eventType,
      occurred_at: new Date(now).toISOString(),
      metadata,
    }
    eventQueueRef.current.push(event)
    lastEventRef.current[eventType] = now
    setMonitoringPending(eventQueueRef.current.length)
    persistEventQueue(eventQueueRef.current)
    return flushMonitoringEvents()
  }, [exam?.attempt_id, flushMonitoringEvents, monitoringActive, persistEventQueue, profile?.id])

  useEffect(() => {
    if (!eventStorageKey || restoredQueueKeyRef.current === eventStorageKey) return
    restoredQueueKeyRef.current = eventStorageKey
    try {
      const restored = JSON.parse(sessionStorage.getItem(eventStorageKey) || '[]')
      if (!Array.isArray(restored)) throw new Error('Stored monitoring queue has an invalid format.')
      eventQueueRef.current = restored.filter(event =>
        event?.attempt_id === exam.attempt_id
        && event?.student_id === profile.id
        && typeof event?.id === 'string'
        && MONITORING_EVENT_TYPES.has(event?.event_type),
      )
      setMonitoringPending(eventQueueRef.current.length)
      if (eventQueueRef.current.length && monitoringActiveRef.current) void flushMonitoringEvents()
    } catch (storageError) {
      setError(`Pending monitoring events could not be restored: ${storageError.message}`)
    }
  }, [eventStorageKey, exam?.attempt_id, flushMonitoringEvents, profile?.id])

  useEffect(() => {
    if (!monitoringPending || !monitoringActive) return
    const retryPending = () => { void flushMonitoringEvents() }
    const onVisibility = () => {
      if (document.visibilityState === 'visible') retryPending()
    }
    window.addEventListener('online', retryPending)
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      window.removeEventListener('online', retryPending)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [flushMonitoringEvents, monitoringActive, monitoringPending])

  useEffect(() => {
    if (!monitoringActive) return
    let wasHidden = document.visibilityState === 'hidden'
    let blurTimer
    const onVisibility = () => {
      const isHidden = document.visibilityState === 'hidden'
      if (isHidden && !wasHidden) {
        wasHidden = true
        clearTimeout(blurTimer)
        const nextSwitchCount = tabSwitchCountRef.current + 1
        tabSwitchCountRef.current = nextSwitchCount
        setTabSwitches(nextSwitchCount)
        void (async () => {
          await recordMonitoringEvent('tab_hidden')
          if (nextSwitchCount > TAB_SWITCHES_ALLOWED) {
            setSubmittedForTabSwitches(true)
            await submit(false)
          }
        })()
      } else if (!isHidden) {
        wasHidden = false
      }
    }
    const onBlur = () => {
      clearTimeout(blurTimer)
      blurTimer = setTimeout(() => {
        if (document.visibilityState !== 'hidden') void recordMonitoringEvent('window_blur')
      }, 150)
    }
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    return () => {
      clearTimeout(blurTimer)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', onBlur)
    }
  }, [monitoringActive, recordMonitoringEvent, submit])

  useEffect(() => {
    if (cameraStream && timerActive && exam?.exam.camera_required) {
      void recordMonitoringEvent('camera_started')
    }
  }, [cameraStream, timerActive, exam?.exam.camera_required, recordMonitoringEvent])

  const startCamera = async () => {
    try {
      const stream = await requestCamera()
      if (stream) await recordMonitoringEvent('camera_started')
    } catch (cameraError) {
      if (cameraError.name === 'NotAllowedError' || cameraError.name === 'SecurityError') {
        await recordMonitoringEvent('camera_denied')
      }
    }
  }

  const stopCamera = async () => {
    const savedEvent = recordMonitoringEvent('camera_stopped')
    cameraStreamRef.current = null
    cameraStream?.getTracks().forEach(track => track.stop())
    setCameraStream(null)
    setCameraStreamStatus('Camera stopped')
    setFaceDetectionStatus('Not started')
    await savedEvent
  }

  useEffect(() => {
    if (!cameraStream) return undefined
    let active = true
    const track = cameraStream.getVideoTracks()[0]
    const onTrackEnded = () => {
      if (cameraStreamRef.current === cameraStream) cameraStreamRef.current = null
      void recordMonitoringEvent('camera_stopped', { reason: 'video_track_ended' })
      setCameraStreamStatus('Camera disconnected')
      setFaceDetectionStatus('Paused · camera stream ended')
      setCameraStream(null)
    }
    track?.addEventListener('ended', onTrackEnded)
    if (!track || track.readyState !== 'live' || !cameraStream.active) {
      onTrackEnded()
      return () => track?.removeEventListener('ended', onTrackEnded)
    }
    if (!videoElement) {
      setCameraStreamStatus('Reconnecting camera preview')
    } else {
      setCameraStreamStatus('Verifying camera preview')
      void waitForVideoPlayback(cameraStream, videoElement).then(() => {
        if (active && cameraStreamRef.current === cameraStream) {
          setCameraStreamStatus('Camera active · video playing')
        }
      }).catch(playError => {
        if (!active) return
        setCameraStreamStatus(
          playError.message?.includes('disconnected') || playError.message?.includes('stopped')
            ? 'Camera disconnected'
            : 'Camera playback failed',
        )
        setError(`Camera preview could not be verified. ${playError.message || 'Video playback failed.'}`)
      })
    }
    return () => {
      active = false
      track?.removeEventListener('ended', onTrackEnded)
      if (videoElement?.srcObject === cameraStream) {
        videoElement.pause()
        videoElement.srcObject = null
      }
    }
  }, [cameraStream, videoElement, waitForVideoPlayback, recordMonitoringEvent])

  useEffect(() => {
    let active = true
    let timer
    let detector
    let detectionRunning = false
    let hasDetectedFrame = false
    if (!cameraStream || !timerActive) {
      setFaceDetectionStatus('Not active')
      return () => { active = false }
    }

    const video = videoElement
    const track = cameraStream.getVideoTracks()[0]
    if (!track || track.readyState !== 'live') {
      setCameraStreamStatus('Camera disconnected')
      setFaceDetectionStatus('Paused')
      return () => { active = false }
    }

    const checkFaces = async () => {
      if (!active || detectionRunning) return
      if (track.readyState !== 'live') {
        setCameraStreamStatus('Stopped by device or browser')
        setFaceDetectionStatus('Paused')
        return
      }
      if (!video || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || video.paused) {
        timer = setTimeout(checkFaces, 1000)
        return
      }
      detectionRunning = true
      try {
        const detection = detector.detectForVideo(video, performance.now())
        const faceCount = detection.detections.length
        if (!hasDetectedFrame) {
          hasDetectedFrame = true
          setFaceDetectionStatus('Active · processed on this device')
        }
        if (faceCount === 0) void recordMonitoringEvent('face_absent')
        if (faceCount > 1) {
          void recordMonitoringEvent('multiple_people', { visible_face_count: Math.min(faceCount, 3) })
        }
      } catch (detectionError) {
        setFaceDetectionStatus('Unavailable: detector error')
        setError(`Local face detection stopped: ${detectionError.message || 'Unable to analyze a camera frame.'}`)
        active = false
        return
      } finally {
        detectionRunning = false
      }
      timer = setTimeout(checkFaces, 2000)
    }

    const initializeDetector = async () => {
      try {
        setFaceDetectionStatus('Loading local detector')
        const vision = await FilesetResolver.forVisionTasks(MEDIAPIPE_WASM_BASE)
        detector = await FaceDetector.createFromOptions(vision, {
          baseOptions: { modelAssetPath: FACE_DETECTOR_MODEL, delegate: 'CPU' },
          runningMode: 'VIDEO',
          minDetectionConfidence: 0.5,
          minSuppressionThreshold: 0.3,
        })
        if (!active) {
          detector.close()
          return
        }
        setFaceDetectionStatus('Detector ready · waiting for camera frame')
        await checkFaces()
      } catch (detectionError) {
        if (!active) return
        setFaceDetectionStatus('Unavailable · model could not load')
        setError(`Local face detection could not start: ${detectionError.message || 'Detector assets are unavailable.'}`)
      }
    }
    void initializeDetector()
    return () => {
      active = false
      clearTimeout(timer)
      detector?.close()
    }
  }, [cameraStream, timerActive, recordMonitoringEvent, videoElement])

  useEffect(() => {
    if (!exam?.attempt_id || timerActive || !cameraStream) return
    cameraStreamRef.current = null
    cameraStream.getTracks().forEach(track => track.stop())
    setCameraStream(null)
    setCameraStreamStatus('Camera stopped')
    setFaceDetectionStatus('Not active')
  }, [exam?.attempt_id, timerActive, cameraStream])

  useEffect(() => () => {
    cameraStreamRef.current?.getTracks().forEach(track => track.stop())
    cameraStreamRef.current = null
  }, [])

  useEffect(() => {
    if (seconds === 0 && !busy && !result && !expired && !submitted) submit(false)
  }, [seconds, busy, result, expired, submitted, submit])

  const refreshPaperUrl = useCallback(async () => {
    if (!paper?.pdf_storage_path) return
    setError('')
    try {
      const url = await createExamPaperSignedUrl(paper.pdf_storage_path, 600)
      setShowPaper(true)
      setPaper(current => ({ ...current, signedUrl: url }))
    } catch (urlError) {
      setError(`The question paper could not be opened: ${urlError.message}`)
    }
  }, [paper?.pdf_storage_path])

  useEffect(() => {
    if (!showPaper || !paper?.pdf_storage_path) return
    const refreshTimer = setInterval(refreshPaperUrl, 8 * 60 * 1000)
    return () => clearInterval(refreshTimer)
  }, [showPaper, paper?.pdf_storage_path, refreshPaperUrl])

  const reportPaper = async event => {
    event.preventDefault()
    const { error: reportError } = await supabase.from('exam_pdf_reports').insert({ exam_id: id, reporter_id: profile.id, reason: reportReason.trim() })
    if (reportError) setReportMessage(reportError.message)
    else { setReportMessage('Report sent to the admin team.'); setReportReason('') }
  }

  const unsyncedMonitoringMessage = monitoringPending
    ? ` ${monitoringPending} monitoring signal(s) could not be synced; they are not available as review records.`
    : ''
  const showCameraPreview = Boolean(cameraStream) || [
    'Requesting camera permission',
    'Camera initializing',
    'Verifying camera preview',
    'Reconnecting camera preview',
    'Camera active · video playing',
  ].includes(cameraStreamStatus)
  const cameraNeedsRetry = [
    'Camera playback failed',
    'Camera initialization failed',
    'Camera initialization failed · unsupported browser',
    'Camera disconnected',
    'No camera device available',
    'Camera permission denied',
  ].includes(cameraStreamStatus)

  if (loading) return <div className="center-screen"><div className="spinner"/></div>
  if (error && !exam && !paper?.camera_required) return <div className="card"><div className="error">{error}</div><button className="btn secondary" onClick={() => navigate('/exams')}>Back to exams</button></div>
  if (!exam && paper?.camera_required) return <section className="card">
    <h2>Camera access required</h2>
    <p>This exam requires camera permission and a working local preview before an attempt begins. Face-presence checks run on this device when supported; camera signals are review indicators, not proof of misconduct. Video is not uploaded or stored.</p>
    <p className="muted small">Allow camera access to start the exam. If permission is denied or unavailable, the exam will not begin.</p>
    <video ref={setVideoRef} autoPlay playsInline muted hidden={!showCameraPreview} className="monitor-camera-preview" style={{ width: '100%', maxWidth: 360, aspectRatio: '4 / 3', objectFit: 'cover', background: '#111', borderRadius: 8 }} aria-label="Local camera preview"/>
    <div className="small">Camera: {cameraStreamStatus} · Permission: {cameraPermissionStatus}</div>
    {error && <div className="error">{error}</div>}
    <div className="row"><button className="btn" disabled={cameraStreamStatus === 'Requesting camera permission'} onClick={startRequiredCamera}>{cameraPermissionStatus === 'Not requested' ? 'Allow camera and start exam' : 'Retry camera and start exam'}</button><button className="btn secondary" onClick={() => navigate('/exams')}>Back to exams</button></div>
  </section>
  if (expired) return <CompletionCard title="Time is up" message="Your attempt was marked as expired." onBack={() => navigate('/exams')}/>
  if (submitted) return <CompletionCard title="Exam submitted" message={`${submittedForTabSwitches ? `Your exam was submitted after more than ${TAB_SWITCHES_ALLOWED} detected tab switches. Monitoring signals are indicators, not proof of misconduct.` : 'Your PDF exam attempt was recorded. This paper is not automatically graded online.'}${unsyncedMonitoringMessage}`} onBack={() => navigate('/exams')}/>
  if (result) return <CompletionCard title="Exam submitted" message={`${submittedForTabSwitches ? `Your exam was submitted after more than ${TAB_SWITCHES_ALLOWED} detected tab switches. Monitoring signals are indicators, not proof of misconduct.` : result.review_required ? 'Your answers are submitted. Descriptive answers need teacher review before the final result is published.' : 'Your answers are submitted. The teacher will publish your result when it is ready.'}${unsyncedMonitoringMessage}`} onBack={() => navigate('/exams')}/>

  const pdfOnly = paper?.exam_type === 'pdf'
  return <>
    <header className="exam-room-header">
      <div><div className="badge">EXAM IN PROGRESS</div><h2>{exam.exam.title}</h2><p className="muted small">{exam.exam.description}</p></div>
      <div className="exam-clock"><Clock3 size={17}/><span>{Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')}</span></div>
    </header>
    {error && <div className="error">{error}</div>}

    {(exam.exam.monitoring_enabled || exam.exam.camera_required) && <section className="notice monitoring-notice">
      <div className="row between"><div className="row"><ShieldAlert size={19}/><div><b>{exam.exam.monitoring_enabled ? 'Exam monitoring is on' : 'Camera is required'}</b><div className="small">Tab and camera signals are review indicators, not proof of misconduct. Video stays on this device and is not recorded or uploaded.</div></div></div><span className="badge">{monitorWarnings} events synced this session</span></div>
      {exam.exam.monitoring_enabled && <p className="small">Tab switches detected: {tabSwitches} · tab events synced this session: {savedTabSwitches} · pending sync: {monitoringPending}. After {TAB_SWITCHES_ALLOWED} allowed switches, the next detected switch submits the exam.</p>}
      {monitoringStorageWarning && <p className="small">{monitoringStorageWarning}</p>}
      <div className="row between monitoring-camera-row"><div><b><Camera size={15}/> Camera: {cameraStreamStatus} · permission: {cameraPermissionStatus}</b><div className="small">Face checks: {faceDetectionStatus}. Inference runs locally; detector assets load from Google and jsDelivr. Camera video is not transmitted. Signals are not proof of misconduct.</div></div>{cameraStream && !cameraNeedsRetry ? (!exam.exam.camera_required && <button type="button" className="btn secondary" onClick={stopCamera}>Turn camera off</button>) : <button type="button" className="btn secondary" disabled={cameraStreamStatus === 'Requesting camera permission'} onClick={startCamera}>{cameraPermissionStatus === 'Granted' ? 'Retry camera' : 'Give camera permission'}</button>}</div>
      <video ref={setVideoRef} autoPlay playsInline muted hidden={!showCameraPreview} className="monitor-camera-preview" style={{ width: '100%', maxWidth: 360, aspectRatio: '4 / 3', objectFit: 'cover', background: '#111', borderRadius: 8 }} aria-label="Local camera preview"/>
    </section>}

    {pdfOnly ? <section className="card pdf-student-card">
      <div className="row"><FileText size={26}/><div><h3>{paper.pdf_filename || 'Question paper PDF'}</h3><p className="muted small">{paper.pdf_size_bytes ? formatFileSize(paper.pdf_size_bytes) : 'Private exam attachment'}</p></div></div>
      <p>Open the question paper below. The exam timer continues while you view it.</p>
      <button className="btn pdf-view-button" onClick={refreshPaperUrl}><FileText size={17}/>{showPaper ? 'Refresh question paper link' : 'View Question Paper PDF'}<RefreshCw size={15}/></button>
      {showPaper && paper.signedUrl && <div className="pdf-student-viewer"><div className="row between pdf-viewer-toolbar"><b>Question paper</b><a href={paper.signedUrl} target="_blank" rel="noreferrer"><ExternalLink size={15}/> Open separately</a></div><iframe title="Exam question paper PDF" src={`${paper.signedUrl}#toolbar=1&navpanes=1&zoom=page-width`}/><p className="muted small">Use the PDF viewer controls to navigate pages and zoom. If your mobile browser cannot display the embedded paper, open it separately using the temporary link above.</p></div>}
      <form className="pdf-report-form" onSubmit={reportPaper}><label htmlFor="paper-report">Report a problem with this paper</label><div className="row"><input className="input" id="paper-report" minLength="5" maxLength="1000" required value={reportReason} onChange={event => setReportReason(event.target.value)} placeholder="Describe the issue"/><button className="btn secondary">Report</button></div>{reportMessage && <p className="muted small">{reportMessage}</p>}</form>
      <button className="btn" disabled={busy} onClick={submit}>{busy ? 'Submitting...' : 'Submit exam'}</button>
    </section> : <div className="exam-questions">
      {exam.questions.map((item, index) => <article className="card" key={item.id}>
        <div className="row between"><span className="badge">QUESTION {index + 1} / {exam.questions.length}</span><span className="muted small">{item.points} points</span></div>
        <h3>{item.prompt}</h3>{item.description && <p className="muted small">{item.description}</p>}
        {['mcq','true_false'].includes(item.question_type || 'mcq') ? item.options.map((option, optionIndex) => <label key={optionIndex} className={`question-option ${answers[item.id] === optionIndex ? 'selected' : ''}`}><input type="radio" name={item.id} checked={answers[item.id] === optionIndex} onChange={() => setAnswers(current => ({ ...current, [item.id]: optionIndex }))}/><span>{option}</span></label>) : <label className="field"><span>{item.question_type === 'long_answer' ? 'Your answer (long answer)' : item.question_type === 'fill_blank' ? 'Your answer' : 'Your answer (short answer)'}</span><textarea className="input" rows={item.question_type === 'long_answer' ? 8 : 3} maxLength={10000} value={answers[item.id] || ''} onChange={event => setAnswers(current => ({ ...current, [item.id]: event.target.value }))}/></label>}
      </article>)}
      {!exam.questions.length && <div className="notice">This exam has no questions yet. Contact the teacher.</div>}
      <button className="btn" disabled={busy || !exam.questions.length} onClick={() => { if (confirm('Submit your answers now?')) submit() }}>{busy ? 'Submitting...' : 'Submit exam'}</button>
    </div>}
  </>
}

function CompletionCard({ title, message, onBack }) {
  return <div className="card exam-completion"><CheckCircle2 size={44} color="#43a36a"/><h2>{title}</h2><p className="muted">{message}</p><button className="btn" onClick={onBack}>Back to exam library</button></div>
}
