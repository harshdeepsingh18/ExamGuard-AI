
import base64
import binascii
import os
import uuid
from datetime import date, datetime, timedelta

from flask import (
    Flask, jsonify, render_template, request,
    redirect, url_for, session, flash
)
from flask_session import Session
from flask_wtf.csrf import CSRFProtect
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

app.secret_key = os.getenv("SECRET_KEY")

# Server-side session configuration
app.config["SESSION_TYPE"] = "filesystem"
app.config["SESSION_PERMANENT"] = False
app.config["SESSION_USE_SIGNER"] = True
app.config["SESSION_FILE_DIR"] = "flask_session"

# Cookie security
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_SECURE"] = os.getenv("SESSION_COOKIE_SECURE", "false").lower() == "true"

# Initialize Flask-Session
Session(app)
CSRFProtect(app)

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024

if not app.secret_key or not SUPABASE_URL or not SUPABASE_KEY:
    raise RuntimeError("Check your .env configuration")

# Create a Supabase client
def get_supabase():
    return create_client(SUPABASE_URL, SUPABASE_KEY)


# Create a client authenticated as the logged-in user
def get_user_client():
    access_token = session.get("access_token")
    refresh_token = session.get("refresh_token")

    if not access_token or not refresh_token:
        return None

    client = get_supabase()
    client.auth.set_session(access_token, refresh_token)
    return client


# Get current user's profile
def get_profile():
    client = get_user_client()

    if not client:
        return None

    user_id = session.get("user_id")

    result = (
        client.table("profiles")
        .select("*")
        .eq("id", user_id)
        .single()
        .execute()
    )

    return result.data


def require_profile(*roles):
    """Return the current profile, or redirect to the appropriate safe page."""
    if not session.get("user_id"):
        return None, redirect(url_for("auth_login"))
    try:
        profile = get_profile()
    except Exception:
        profile = None
    if not profile:
        session.clear()
        return None, redirect(url_for("auth_login"))
    if roles and profile.get("role") not in roles:
        return None, redirect(url_for("dashboard"))
    return profile, None


def format_exam_time(exam):
    return f"{exam.get('exam_date', '')} {str(exam.get('start_time', ''))[:5]}"


# Homepage
@app.route("/")
def home():
    return render_template("index.html")


# Role selection
@app.route("/login")
def login():
    if session.get("user_id"):
        return redirect(url_for("dashboard"))

    return render_template("login.html")


# Registration
@app.route("/register", methods=["GET", "POST"])
def register():

    if request.method == "POST":

        full_name = request.form.get("full_name", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        password_confirm = request.form.get("confirm_password", "")
        role = request.form.get("role", "student")

        if not full_name or not email or not password:
            return render_template(
                "register.html", error="Please fill all fields."
            )

        if password != password_confirm:
            return render_template("register.html", error="Passwords do not match.")

        if len(password) < 8:
            return render_template(
                "register.html",
                error="Password must contain at least 8 characters."
            )

        if role not in ["student", "teacher"]:
            return render_template(
                "register.html", error="Invalid account type."
            )

        try:
            client = get_supabase()

            response = client.auth.sign_up({
                "email": email,
                "password": password,
                "options": {
                    "data": {
                        "full_name": full_name,
                        "requested_role": role
                    }
                }
            })

            if response.session:
                return redirect(url_for("auth_login"))

            return render_template(
                "auth_login.html",
                message="Registration successful! Check your email to confirm your account, then login."
            )

        except Exception as error:
            print("Registration error:", error)

            return render_template(
                "register.html",
                error="Registration failed. Check your email or try another account."
            )

    return render_template("register.html")


@app.route("/forgot-password", methods=["GET", "POST"])
def forgot_password():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        if not email:
            return render_template("forgot_password.html", error="Enter the email address for your account.")
        try:
            redirect_to = os.getenv("PASSWORD_RESET_REDIRECT_URL", url_for("reset_password", _external=True))
            get_supabase().auth.reset_password_for_email(email, options={"redirect_to": redirect_to})
            return render_template("forgot_password.html", message="If the address is registered, a password reset link will be emailed to it.")
        except Exception as error:
            print("Password reset request error:", error)
            return render_template("forgot_password.html", error="Password reset could not be started. Try again later.")
    return render_template("forgot_password.html")


@app.route("/reset-password", methods=["GET", "POST"])
def reset_password():
    if request.method == "POST":
        password = request.form.get("password", "")
        confirmation = request.form.get("confirm_password", "")
        if len(password) < 8 or password != confirmation:
            return render_template("reset_password.html", error="Use matching passwords with at least 8 characters.")
        try:
            access_token = request.form.get("access_token") or session.get("reset_access_token")
            refresh_token = request.form.get("refresh_token") or session.get("reset_refresh_token")
            if access_token and refresh_token:
                client = get_supabase()
                client.auth.set_session(access_token, refresh_token)
                client.auth.update_user({"password": password})
            elif session.get("access_token") and session.get("refresh_token"):
                client = get_user_client()
                client.auth.update_user({"password": password})
            else:
                raise ValueError("A valid password recovery session is required.")
            session.pop("reset_access_token", None)
            session.pop("reset_refresh_token", None)
            return render_template("auth_login.html", message="Password updated. You can now log in.")
        except Exception as error:
            print("Password update error:", error)
            return render_template("reset_password.html", error="The reset link is invalid or expired. Request a new link.")
    token_hash = request.args.get("token_hash")
    if token_hash:
        try:
            recovery = get_supabase().auth.verify_otp({"token_hash": token_hash, "type": "recovery"})
            if not recovery.session:
                raise ValueError("Recovery link did not create a session.")
            session["reset_access_token"] = recovery.session.access_token
            session["reset_refresh_token"] = recovery.session.refresh_token
            return redirect(url_for("reset_password"))
        except Exception as error:
            print("Password recovery verification error:", error)
            return render_template("reset_password.html", error="The recovery link is invalid or expired. Request a new link.")
    return render_template("reset_password.html", access_token=session.get("reset_access_token", ""), refresh_token=session.get("reset_refresh_token", ""))


# Actual login
@app.route("/auth-login", methods=["GET", "POST"])
def auth_login():

    if request.method == "POST":

        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")

        try:
            client = get_supabase()

            response = client.auth.sign_in_with_password({
                "email": email,
                "password": password
            })

            if not response.session:
                return render_template(
                    "auth_login.html",
                    error="Please verify your email before logging in."
                )

            session.clear()

            session["access_token"] = response.session.access_token
            session["refresh_token"] = response.session.refresh_token
            session["user_id"] = response.user.id

            return redirect(url_for("dashboard"))

        except Exception as error:
            print("Login error:", error)

            return render_template(
                "auth_login.html",
                error="Invalid email or password, or email not confirmed."
            )

    return render_template("auth_login.html")


# Dashboard routing according to account role
@app.route("/dashboard")
def dashboard():

    try:
        profile = get_profile()

        if not profile:
            session.clear()
            return redirect(url_for("auth_login"))

        if profile["role"] == "teacher" and profile["teacher_approved"]:
            return redirect(url_for("teacher"))

        if profile["requested_role"] == "teacher":
            return render_template(
                "student.html",
                profile=profile,
                pending_approval=True
            )

        return redirect(url_for("student"))

    except Exception as error:
        print("Dashboard error:", error)
        session.clear()
        return redirect(url_for("auth_login"))


# Student dashboard
@app.route("/student")
def student():

    try:
        profile = get_profile()

        if not profile:
            return redirect(url_for("auth_login"))

        if profile["role"] != "student":
            return redirect(url_for("dashboard"))

        client = get_user_client()
        exams = client.table("exams").select("id", count="exact").eq("published", True).execute().count or 0
        attempts = client.table("exam_attempts").select("id,status").eq("student_id", profile["id"]).execute().data or []
        results = client.table("exam_results").select("marks_obtained,total_marks").eq("student_id", profile["id"]).eq("published", True).execute().data or []
        average = round(sum(float(row["marks_obtained"]) / float(row["total_marks"]) * 100 for row in results if float(row["total_marks"]) > 0) / len(results)) if results else 0
        return render_template("student.html", profile=profile, pending_approval=False,
                               total_exams=exams, completed_exams=sum(1 for a in attempts if a["status"] != "in_progress"),
                               results_count=len(results), average_score=average)

    except Exception as error:
        print("Student dashboard error:", error)
        return redirect(url_for("auth_login"))


# Teacher dashboard
@app.route("/teacher")
def teacher():

    try:
        profile = get_profile()

        if not profile:
            return redirect(url_for("auth_login"))

        if profile["role"] != "teacher" or not profile["teacher_approved"]:
            return redirect(url_for("dashboard"))

        return render_template(
            "teacher.html",
            profile=profile,
            exam_count=(get_user_client().table("exams").select("id", count="exact").eq("teacher_id", profile["id"]).execute().count or 0),
            published_count=(get_user_client().table("exams").select("id", count="exact").eq("teacher_id", profile["id"]).eq("published", True).execute().count or 0),
            submission_count=(get_user_client().table("exam_attempts").select("id", count="exact").execute().count or 0)
        )

    except Exception as error:
        print("Teacher dashboard error:", error)
        return redirect(url_for("auth_login"))


# Teacher exam management. New exams stay unpublished until the teacher reviews
# the extracted paper, adds structured questions, and explicitly publishes.
@app.route("/teacher/exams", methods=["GET", "POST"])
def teacher_exams():
    profile, response = require_profile("teacher")
    if response:
        return response
    if not profile.get("teacher_approved"):
        flash("Your teacher account is awaiting administrator approval.", "error")
        return redirect(url_for("dashboard"))

    client = get_user_client()
    if request.method == "POST":
        try:
            title = request.form.get("title", "").strip()
            subject = request.form.get("subject", "").strip()
            description = request.form.get("description", "").strip()
            exam_date = request.form.get("exam_date", "")
            start_time = request.form.get("start_time", "")
            duration = int(request.form.get("duration_minutes", "0"))
            total_marks = float(request.form.get("total_marks", "0"))
            passing_marks = float(request.form.get("passing_marks", "0"))
            rules = request.form.get("rules", "").strip()
            if not title or not subject or not exam_date or not start_time:
                raise ValueError("Complete all required exam details.")
            date.fromisoformat(exam_date)
            datetime.strptime(start_time, "%H:%M")
            if not 1 <= duration <= 600 or total_marks <= 0 or not 0 <= passing_marks <= total_marks:
                raise ValueError("Check duration and marks; values must be within the allowed range.")

            exam_id = str(uuid.uuid4())
            uploaded = request.files.get("question_paper")
            paper_path = None
            extracted_text = ""
            if uploaded and uploaded.filename:
                if not uploaded.filename.lower().endswith(".pdf"):
                    raise ValueError("Question papers must be PDF files.")
                pdf_bytes = uploaded.read()
                if not pdf_bytes.startswith(b"%PDF-"):
                    raise ValueError("The uploaded file is not a valid PDF.")
                try:
                    import fitz
                    document = fitz.open(stream=pdf_bytes, filetype="pdf")
                    extracted_text = "\n\n".join(page.get_text() for page in document).strip()
                    document.close()
                except Exception as pdf_error:
                    raise ValueError("This PDF could not be read. Please try another PDF.") from pdf_error
                if not extracted_text:
                    raise ValueError("This PDF appears to be scanned and contains no selectable text. OCR is not configured yet; upload a text-based PDF.")
                paper_path = f"{profile['id']}/{exam_id}.pdf"
                client.storage.from_("question-papers").upload(
                    paper_path, pdf_bytes,
                    file_options={"content-type": "application/pdf", "upsert": "false"}
                )

            client.table("exams").insert({
                "id": exam_id, "teacher_id": profile["id"], "title": title,
                "subject": subject, "description": description,
                "exam_date": exam_date, "start_time": start_time,
                "duration_minutes": duration, "total_marks": total_marks,
                "passing_marks": passing_marks, "rules": rules,
                "question_paper_path": paper_path, "extracted_text": extracted_text,
                "published": False
            }).execute()
            flash("Exam saved as a draft. Review the extracted text and add questions before publishing.", "success")
            return redirect(url_for("edit_exam", exam_id=exam_id))
        except ValueError as error:
            flash(str(error), "error")
        except Exception as error:
            print("Exam creation error:", error)
            flash("Could not create the exam. Check your connection and try again.", "error")

    try:
        exams = client.table("exams").select("*").eq("teacher_id", profile["id"]).order("created_at", desc=True).execute().data or []
    except Exception as error:
        print("Exam list error:", error)
        exams = []
        flash("Exams could not be loaded. Apply the Supabase schema and try again.", "error")
    return render_template("teacher_exams.html", profile=profile, exams=exams)


@app.route("/teacher/exams/<exam_id>", methods=["GET", "POST"])
def edit_exam(exam_id):
    profile, response = require_profile("teacher")
    if response:
        return response
    if not profile.get("teacher_approved"):
        flash("Your teacher account is awaiting administrator approval.", "error")
        return redirect(url_for("dashboard"))
    client = get_user_client()
    try:
        exam = client.table("exams").select("*").eq("id", exam_id).single().execute().data
        questions = client.table("questions").select("*").eq("exam_id", exam_id).order("position").execute().data or []
        if request.method == "POST":
            if exam.get("published"):
                flash("Published exams cannot be changed.", "error")
                return redirect(url_for("edit_exam", exam_id=exam_id))
            if request.form.get("action") == "publish":
                if not questions:
                    flash("Add at least one question before publishing.", "error")
                elif abs(sum(float(q["marks"]) for q in questions) - float(exam["total_marks"])) > 0.0001:
                    flash("Question marks must add up to the exam total before publishing.", "error")
                else:
                    client.table("exams").update({"published": True}).eq("id", exam_id).execute()
                    flash("Exam published and available to students.", "success")
            else:
                prompt = request.form.get("prompt", "").strip()
                kind = request.form.get("question_type", "multiple_choice")
                marks = float(request.form.get("marks", "0"))
                options_text = request.form.get("options", "")
                correct = request.form.get("correct_answer", "").strip()
                allowed = {"multiple_choice", "multiple_select", "true_false", "short_answer", "long_answer"}
                if not prompt or kind not in allowed or marks <= 0:
                    raise ValueError("Enter a question, type, and positive mark value.")
                options = [line.strip() for line in options_text.splitlines() if line.strip()]
                if kind in ("multiple_choice", "multiple_select") and len(options) < 2:
                    raise ValueError("Add at least two answer options.")
                if kind in ("multiple_choice", "multiple_select", "true_false") and not correct:
                    raise ValueError("Provide the correct answer for this question type.")
                if kind == "true_false":
                    options = ["True", "False"]
                    if correct.lower() not in ("true", "false"):
                        raise ValueError("The correct answer must be True or False.")
                    correct = "True" if correct.lower() == "true" else "False"
                if kind == "multiple_choice" and correct not in options:
                    raise ValueError("The correct answer must match one of the options exactly.")
                if kind == "multiple_select":
                    selected = [part.strip() for part in correct.split(",") if part.strip()]
                    if not selected or any(answer not in options for answer in selected):
                        raise ValueError("Each correct answer must match an option exactly.")
                question_id = str(uuid.uuid4())
                client.table("questions").insert({
                    "id": question_id, "exam_id": exam_id,
                    "position": len(questions) + 1, "question_type": kind,
                    "prompt": prompt, "options": options, "marks": marks
                }).execute()
                if kind in ("multiple_choice", "multiple_select", "true_false"):
                    if kind == "multiple_select":
                        answer_key = sorted(set(part.strip() for part in correct.split(",") if part.strip()))
                    else:
                        answer_key = correct
                    client.table("question_keys").insert({"question_id": question_id, "correct_answer": answer_key}).execute()
                flash("Question added.", "success")
            return redirect(url_for("edit_exam", exam_id=exam_id))
    except ValueError as error:
        flash(str(error), "error")
        return redirect(url_for("edit_exam", exam_id=exam_id))
    except Exception as error:
        print("Exam editor error:", error)
        flash("Could not load or update this exam.", "error")
        return redirect(url_for("teacher_exams"))
    return render_template("edit_exam.html", profile=profile, exam=exam, questions=questions)


@app.route("/exams")
def available_exams():
    profile, response = require_profile("student")
    if response:
        return response
    try:
        exams = get_user_client().table("exams").select("*").eq("published", True).order("exam_date").execute().data or []
        attempts = get_user_client().table("exam_attempts").select("exam_id,status").eq("student_id", profile["id"]).execute().data or []
        attempt_status = {item["exam_id"]: item["status"] for item in attempts}
    except Exception as error:
        print("Available exams error:", error)
        exams, attempt_status = [], {}
        flash("Exams could not be loaded. Apply the Supabase schema and try again.", "error")
    return render_template("available_exams.html", profile=profile, exams=exams, attempt_status=attempt_status)


@app.route("/exam/<exam_id>", methods=["GET", "POST"])
def take_exam(exam_id):
    profile, response = require_profile("student")
    if response:
        return response
    client = get_user_client()
    try:
        exam = client.table("exams").select("*").eq("id", exam_id).eq("published", True).single().execute().data
        existing = client.table("exam_attempts").select("*").eq("exam_id", exam_id).eq("student_id", profile["id"]).execute().data or []
        if existing and existing[0]["status"] != "in_progress":
            flash("This exam has already been submitted.", "error")
            return redirect(url_for("student_results"))
        if not existing:
            attempt = client.table("exam_attempts").insert({"exam_id": exam_id, "student_id": profile["id"]}).execute().data[0]
        else:
            attempt = existing[0]
        questions = client.table("questions").select("id,position,question_type,prompt,options,marks").eq("exam_id", exam_id).order("position").execute().data or []
        answers = client.table("student_answers").select("question_id,answer").eq("attempt_id", attempt["id"]).execute().data or []
    except Exception as error:
        print("Exam start error:", error)
        flash("This exam could not be opened.", "error")
        return redirect(url_for("available_exams"))
    return render_template("exam.html", profile=profile, exam=exam, attempt=attempt, questions=questions, answers={a["question_id"]: a["answer"] for a in answers})


@app.route("/api/attempt/<attempt_id>/answer", methods=["POST"])
def save_answer(attempt_id):
    profile, response = require_profile("student")
    if response:
        return jsonify(error="Please log in as a student."), 401
    payload = request.get_json(silent=True) or {}
    question_id = payload.get("question_id")
    answer = payload.get("answer")
    if not question_id or answer is None:
        return jsonify(error="A question and answer are required."), 400
    try:
        client = get_user_client()
        attempt = client.table("exam_attempts").select("id,status").eq("id", attempt_id).eq("student_id", profile["id"]).single().execute().data
        if attempt["status"] != "in_progress":
            return jsonify(error="This exam has already been submitted."), 409
        client.table("student_answers").upsert({"attempt_id": attempt_id, "question_id": question_id, "answer": answer}, on_conflict="attempt_id,question_id").execute()
        return jsonify(saved=True)
    except Exception as error:
        print("Answer save error:", error)
        return jsonify(error="Answer could not be saved."), 400


@app.route("/api/attempt/<attempt_id>/event", methods=["POST"])
def log_proctor_event(attempt_id):
    profile, response = require_profile("student")
    if response:
        return jsonify(error="Please log in as a student."), 401
    payload = request.get_json(silent=True) or {}
    event_type = payload.get("event_type")
    allowed = {"tab_hidden", "fullscreen_exit", "face_missing", "multiple_faces", "camera_error"}
    if event_type not in allowed:
        return jsonify(error="Unsupported monitoring event."), 400
    try:
        client = get_user_client()
        attempt = client.table("exam_attempts").select("id,status").eq("id", attempt_id).eq("student_id", profile["id"]).single().execute().data
        if attempt["status"] != "in_progress":
            return jsonify(error="This exam has already been submitted."), 409
        event_times = session.get("proctor_event_times", {})
        last_at = event_times.get(event_type, 0)
        now = datetime.now().timestamp()
        if now - last_at < 2:
            return jsonify(recorded=True, throttled=True)
        client.table("proctoring_events").insert({"attempt_id": attempt_id, "event_type": event_type, "details": {}}).execute()
        event_times[event_type] = now
        session["proctor_event_times"] = event_times
        return jsonify(recorded=True)
    except Exception as error:
        print("Monitoring log error:", error)
        return jsonify(error="Monitoring event could not be saved."), 400


@app.route("/api/attempt/<attempt_id>/face-check", methods=["POST"])
def detect_exam_faces(attempt_id):
    profile, response = require_profile("student")
    if response:
        return jsonify(error="Please log in as a student."), 401
    payload = request.get_json(silent=True) or {}
    frame_data = payload.get("frame", "")
    if not isinstance(frame_data, str) or len(frame_data) > 700_000:
        return jsonify(error="Camera frame is too large."), 413
    if "," in frame_data:
        frame_data = frame_data.split(",", 1)[1]
    try:
        raw_frame = base64.b64decode(frame_data, validate=True)
        if not raw_frame or len(raw_frame) > 512_000:
            return jsonify(error="Camera frame is too large."), 413
        client = get_user_client()
        attempt = client.table("exam_attempts").select("id,status").eq("id", attempt_id).eq("student_id", profile["id"]).single().execute().data
        if attempt["status"] != "in_progress":
            return jsonify(error="This exam has already been submitted."), 409
        import cv2
        import mediapipe as mp
        import numpy as np
        frame = cv2.imdecode(np.frombuffer(raw_frame, dtype=np.uint8), cv2.IMREAD_COLOR)
        if frame is None:
            return jsonify(error="Camera frame could not be read."), 400
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        with mp.solutions.face_detection.FaceDetection(model_selection=0, min_detection_confidence=0.55) as detector:
            detection = detector.process(rgb_frame)
        faces = len(detection.detections or [])
        return jsonify(face_count=faces)
    except (binascii.Error, ValueError):
        return jsonify(error="Camera frame could not be decoded."), 400
    except ImportError:
        return jsonify(error="Face detection dependencies are unavailable on this server."), 503
    except Exception as error:
        print("Face detection error:", error)
        return jsonify(error="Face detection is temporarily unavailable."), 503


@app.route("/exam/<exam_id>/submit", methods=["POST"])
def submit_exam(exam_id):
    profile, response = require_profile("student")
    if response:
        return response
    try:
        client = get_user_client()
        attempt = client.table("exam_attempts").select("id,status").eq("exam_id", exam_id).eq("student_id", profile["id"]).single().execute().data
        if attempt["status"] == "in_progress":
            client.table("exam_attempts").update({"status": "submitted"}).eq("id", attempt["id"]).execute()
        flash("Your answers were submitted. Results will be available after review.", "success")
        return redirect(url_for("student_results"))
    except Exception as error:
        print("Exam submission error:", error)
        flash("Your exam could not be submitted. Check your connection and try again.", "error")
        return redirect(url_for("take_exam", exam_id=exam_id))


@app.route("/results")
def student_results():
    profile, response = require_profile("student")
    if response:
        return response
    try:
        results = get_user_client().table("exam_results").select("*,exams(title,subject)").eq("student_id", profile["id"]).eq("published", True).order("graded_at", desc=True).execute().data or []
    except Exception as error:
        print("Student result error:", error)
        results = []
        flash("Results could not be loaded. Apply the Supabase schema and try again.", "error")
    return render_template("results.html", profile=profile, results=results)


@app.route("/teacher/results")
def teacher_results():
    profile, response = require_profile("teacher")
    if response:
        return response
    if not profile.get("teacher_approved"):
        flash("Your teacher account is awaiting administrator approval.", "error")
        return redirect(url_for("dashboard"))
    try:
        client = get_user_client()
        exams = client.table("exams").select("id,title").eq("teacher_id", profile["id"]).execute().data or []
        results = []
        for exam in exams:
            rows = client.table("exam_results").select("*").eq("exam_id", exam["id"]).execute().data or []
            for row in rows:
                row["exam_title"] = exam["title"]
                people = client.table("profiles").select("full_name").eq("id", row["student_id"]).execute().data or []
                row["student_name"] = people[0]["full_name"] if people else "Student"
                row["answers"] = client.table("student_answers").select("id,answer,marks_awarded,questions(prompt,question_type,marks)").eq("attempt_id", row["attempt_id"]).execute().data or []
                row["events"] = client.table("proctoring_events").select("event_type,occurred_at").eq("attempt_id", row["attempt_id"]).order("occurred_at").execute().data or []
                results.append(row)
    except Exception as error:
        print("Teacher results error:", error)
        exams, results = [], []
        flash("Reports could not be loaded.", "error")
    return render_template("teacher_results.html", profile=profile, results=results)


@app.route("/teacher/answers/<answer_id>/grade", methods=["POST"])
def grade_answer(answer_id):
    profile, response = require_profile("teacher")
    if response:
        return response
    try:
        marks = float(request.form.get("marks_awarded", "-1"))
        get_user_client().rpc("grade_submission_answer", {"target_answer": answer_id, "awarded": marks}).execute()
        flash("Written answer graded.", "success")
    except Exception as error:
        print("Answer grading error:", error)
        flash("Answer could not be graded. Check the mark limit and whether the result is already published.", "error")
    return redirect(url_for("teacher_results"))


@app.route("/teacher/results/<result_id>/publish", methods=["POST"])
def publish_result(result_id):
    profile, response = require_profile("teacher")
    if response:
        return response
    try:
        get_user_client().rpc("publish_exam_result", {"target_result": result_id}).execute()
        flash("Result published for the student.", "success")
    except Exception as error:
        print("Result publish error:", error)
        flash("Result could not be published.", "error")
    return redirect(url_for("teacher_results"))


# Logout
@app.route("/logout", methods=["POST"])
def logout():

    try:
        client = get_user_client()

        if client:
            client.auth.sign_out()

    except Exception as error:
        print("Logout error:", error)

    session.clear()

    return redirect(url_for("home"))


if __name__ == "__main__":
    app.run(debug=True)
