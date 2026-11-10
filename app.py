
import os

from flask import (
    Flask, render_template, request,
    redirect, url_for, session, flash
)
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)

app.secret_key = os.getenv("SECRET_KEY")

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")

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
        role = request.form.get("role", "student")

        if not full_name or not email or not password:
            return render_template(
                "register.html", error="Please fill all fields."
            )

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

        return render_template(
            "student.html",
            profile=profile,
            pending_approval=False
        )

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
            profile=profile
        )

    except Exception as error:
        print("Teacher dashboard error:", error)
        return redirect(url_for("auth_login"))


# Logout
@app.route("/logout")
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
