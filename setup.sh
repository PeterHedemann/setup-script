#!/usr/bin/env bash

# bash <(curl -fsSL https://gist.githubusercontent.com/PeterHedemann/1c1d6235c57483f4b6081f683cf953b7/raw) {foldername}

set -euo pipefail

PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: ./setup-next-better-auth.sh <project-folder>"
  exit 1
fi

echo "Creating project in: $PROJECT_DIR"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
PROJECT_NAME="$(basename "$PWD")"

echo "Creating Next.js app..."
npx create-next-app@latest .  \
  --typescript \
  --tailwind \
  --eslint \
  --app \
  --use-npm \
  --yes

echo "Installing dependencies..."
# Better Auth supports Prisma 5–7; keep all Prisma packages on major 7
# instead of allowing the default npm tag to select Prisma 8 prereleases.
npm install prisma@7 @types/node --save-dev
npm install @prisma/client@7 @prisma/adapter-mariadb@7 dotenv better-auth @better-auth/prisma-adapter @better-auth/passkey resend zod

echo "Initializing Prisma..."
npx prisma init --datasource-provider mysql --output ../generated/prisma

echo "Adding shadow database URL to Prisma config..."
if ! grep -Fq 'url: process.env["DATABASE_URL"],' prisma7.config.ts; then
  echo 'Error: Could not find datasource url in prisma7.config.ts.' >&2
  echo 'Expected line: url: process.env["DATABASE_URL"],' >&2
  exit 1
fi

if ! grep -Fq "shadowDatabaseUrl:" prisma7.config.ts; then
  awk '
    {
      print
      if ($0 ~ /^[[:space:]]*url: process\.env\["DATABASE_URL"\],/) {
        match($0, /^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        print indent "shadowDatabaseUrl: process.env['\''SHADOW_DATABASE_URL'\''],"
      }
    }
  ' prisma7.config.ts > prisma7.config.ts.tmp
  mv prisma7.config.ts.tmp prisma7.config.ts
fi

npx prisma generate

echo "Writing .env..."
BETTER_AUTH_SECRET="$(openssl rand -base64 48)"
cat > .env <<EOF
BETTER_AUTH_SECRET="$BETTER_AUTH_SECRET"
BETTER_AUTH_URL=http://localhost:3000
DATABASE_URL="mysql://myuser:mypass@127.0.0.1:3306/app_dev"
SHADOW_DATABASE_URL="mysql://myuser:mypass@127.0.0.1:3306/app_shadow"
NODE_ENV="development"
PORT=3000

# Production only: use a sender on a verified Resend domain.
RESEND_API_KEY=<PROD ONLY>
RESEND_FROM_EMAIL="Monopopoly <auth@example.com>"
EOF

echo "Writing .env.example..."
cat > .env.example <<EOF
BETTER_AUTH_SECRET=<your-secret-here>
BETTER_AUTH_URL=http://localhost:3000
DATABASE_URL="mysql://myuser:mypass@127.0.0.1:3306/app_dev"
SHADOW_DATABASE_URL="mysql://myuser:mypass@127.0.0.1:3306/app_shadow"
NODE_ENV="development"
PORT=3000
# Production only: use a sender on a verified Resend domain.
RESEND_API_KEY=API_KEY_HERE
RESEND_FROM_EMAIL="Monopopoly <auth@example.com>"
EOF

echo "Creating folders..."
mkdir -p lib
mkdir -p lib/actions
mkdir -p app/api/auth/[...all]
mkdir -p app/signin
mkdir -p app/signin
mkdir -p app/components
mkdir -p app/signup
mkdir -p app/signedout
mkdir -p init-db

echo "Writing lib/prisma.ts..."
cat > lib/prisma.ts <<'EOF'
import { PrismaClient } from "../generated/prisma/client";
import { PrismaMariaDb } from "@prisma/adapter-mariadb";

const globalForPrisma = global as unknown as {
  prisma: PrismaClient | undefined;
};

const databaseUrl = process.env.DATABASE_URL;

if (!databaseUrl) {
  throw new Error("DATABASE_URL is required");
}

const connectionUrl = new URL(databaseUrl);

if (connectionUrl.protocol !== "mysql:") {
  throw new Error("DATABASE_URL must use the mysql protocol");
}

const adapter = new PrismaMariaDb({
  host: connectionUrl.hostname,
  port: connectionUrl.port ? Number(connectionUrl.port) : 3306,
  user: decodeURIComponent(connectionUrl.username),
  password: decodeURIComponent(connectionUrl.password),
  database: connectionUrl.pathname.replace(/^\//, ""),
  connectionLimit: 5,
});

export const prisma =
  globalForPrisma.prisma ??
  new PrismaClient({
    adapter,
  });

if (process.env.NODE_ENV !== "production") {
  globalForPrisma.prisma = prisma;
}
EOF

echo "Writing lib/auth.ts..."
cat > lib/auth.ts <<'EOF'
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { nextCookies } from "better-auth/next-js";
import { emailOTP } from "better-auth/plugins";
import { passkey } from "@better-auth/passkey";
import { prisma } from "./prisma";
import { sendVerificationCode } from "./email";

const origin = new URL(process.env.BETTER_AUTH_URL ?? "http://localhost:3000").origin;

export const auth = betterAuth({
  database: prismaAdapter(prisma, { provider: "mysql" }),
  emailAndPassword: { enabled: false },
  rateLimit: { enabled: true },
  plugins: [
    emailOTP({
      otpLength: 6,
      expiresIn: 300,
      allowedAttempts: 3,
      storeOTP: "hashed",
      async sendVerificationOTP({ email, otp }) {
        await sendVerificationCode(email, otp);
      },
    }),
    passkey({
      rpID: new URL(origin).hostname,
      rpName: "Monopopoly",
      origin,
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
    }),
    nextCookies(),
  ],
});
EOF

echo "Writing auth route..."
cat > app/api/auth/[...all]/route.ts <<'EOF'
import { auth } from "@/lib/auth";
import { toNextJsHandler } from "better-auth/next-js";

export const { POST, GET } = toNextJsHandler(auth);
EOF

echo "Writing app/page.tsx..."
cat > app/page.tsx <<'EOF'
import { getCurrentUser } from "@/lib/users";
import { SignOutAction } from "@/lib/actions/signout";
import Link from "next/link";

export default async function Home() {
  const user = await getCurrentUser();

  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-6 text-zinc-950">
      <section className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-8 shadow-sm">
        <p className="text-sm font-medium text-zinc-500">Authentication status</p>
        <h1 className="mt-3 text-3xl font-semibold">
          {user ? "You are logged in." : "You are logged out."}
        </h1>

        <div className="mt-6 rounded-md bg-zinc-100 p-4 text-sm text-zinc-700">
          {user ? (
            <div className="space-y-1">
              <p>
                <span className="font-medium text-zinc-950">Name:</span>{" "}
                {user.name}
              </p>
              <p>
                <span className="font-medium text-zinc-950">Email:</span>{" "}
                {user.email}
              </p>
            </div>
          ) : (
            <p>No active BetterAuth session was found.</p>
          )}
        </div>

        <div className="mt-6 flex gap-3">
          {user ? (
            <form action={SignOutAction}>
              <button
                type="submit"
                className="inline-flex rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
              >
                Sign out
              </button>
            </form>
          ) : (
            <>
              <Link
                href="/signin"
                className="inline-flex rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
              >
                Sign in
              </Link>
              <Link
                href="/signup"
                className="inline-flex rounded-md border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 hover:border-zinc-950 hover:text-zinc-950"
              >
                Sign up
              </Link>
            </>
          )}
        </div>
      </section>
    </main>
  );
}
EOF

echo "Writing app/layout.tsx..."
cat > app/layout.tsx <<'EOF'
import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

export const metadata: Metadata = {
  title: "Create Next App",
  description: "Generated by create next app",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
EOF

echo "Writing app/loading.tsx..."
cat > app/loading.tsx <<'EOF'
export default function Loading() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-6 text-zinc-950">
      <section className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-8 shadow-sm">
        <p role="status" className="text-sm font-medium text-zinc-500">
          Loading...
        </p>
      </section>
    </main>
  );
}
EOF

echo "Writing app/globals.css..."
cat > app/globals.css <<'EOF'
@import "tailwindcss";

:root {
  --background: #ffffff;
  --foreground: #171717;
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --font-sans: var(--font-geist-sans);
  --font-mono: var(--font-geist-mono);
}

@media (prefers-color-scheme: dark) {
  :root {
    --background: #0a0a0a;
    --foreground: #ededed;
  }
}

body {
  background: var(--background);
  color: var(--foreground);
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;
}
EOF

echo "Writing app/components/email-code-form.tsx..."
cat > app/components/email-code-form.tsx <<'EOF'
"use client";

import { useState, type FormEvent } from "react";
import { authClient } from "@/lib/auth-client";

const inputClass = "mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950";
export const buttonClass = "w-full rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:cursor-not-allowed disabled:bg-zinc-500";

export function EmailCodeForm({ onVerified }: { onVerified: (email: string) => void }) {
  const [email, setEmail] = useState("");
  const [otp, setOtp] = useState("");
  const [sent, setSent] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  async function sendCode() {
    setPending(true);
    setError("");
    setNotice("");
    try {
      const result = await authClient.emailOtp.sendVerificationOtp({ email: email.trim(), type: "sign-in" });
      if (result.error) { setError(result.error.message ?? "Unable to send a code. Please try again."); return; }
      setSent(true);
      setOtp("");
      setNotice("A new code has been sent. It expires in five minutes.");
    } catch { setError("Unable to send a code. Please try again."); }
    finally { setPending(false); }
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!sent) { await sendCode(); return; }
    setPending(true);
    setError("");
    try {
      const result = await authClient.signIn.emailOtp({ email: email.trim(), otp, name: email.trim() });
      if (result.error) { setError(result.error.message ?? "Unable to verify this code."); return; }
      onVerified(result.data.user.email);
    } catch { setError("Unable to verify this code. Please try again."); }
    finally { setPending(false); }
  }

  return (
    <form onSubmit={submit} className="mt-6 space-y-4">
      {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
      {notice && <p role="status" className="text-sm text-zinc-600">{notice}</p>}
      <label className="block text-sm font-medium">Email
        <input type="email" name="email" autoComplete="email" required value={email} disabled={sent || pending}
          onChange={(event) => setEmail(event.target.value)} className={inputClass} />
      </label>
      {sent && <label className="block text-sm font-medium">Verification code
        <input name="otp" autoComplete="one-time-code" inputMode="numeric" pattern="[0-9]{6}" maxLength={6}
          required value={otp} disabled={pending} onChange={(event) => setOtp(event.target.value)} className={inputClass} />
      </label>}
      <button disabled={pending} className={buttonClass}>
        {pending ? "Please wait..." : sent ? "Verify email" : "Send verification code"}
      </button>
      {sent && <div className="flex justify-between text-sm">
        <button type="button" disabled={pending} onClick={sendCode}>Resend code</button>
        <button type="button" disabled={pending} onClick={() => { setSent(false); setOtp(""); setError(""); setNotice(""); }}>Use another email</button>
      </div>}
    </form>
  );
}
EOF

echo "Writing app/signin/page.tsx..."
cat > app/signin/page.tsx <<'EOF'
import Link from "next/link";
import { SignInForm } from "./signin-form";

export default function SignInPage() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-6 text-zinc-950">
      <section className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-8 shadow-sm">
        <p className="text-sm font-medium text-zinc-500">Welcome back</p>
        <h1 className="mt-3 text-3xl font-semibold">Sign in</h1>

        <SignInForm />

        <div className="mt-6 flex gap-4 text-sm font-medium">
          <Link href="/" className="text-zinc-600 hover:text-zinc-950">
            Back home
          </Link>
          <Link href="/signup" className="text-zinc-600 hover:text-zinc-950">
            Create account
          </Link>
        </div>
      </section>
    </main>
  );
}
EOF

echo "Writing app/signin/signin-form.tsx..."
cat > app/signin/signin-form.tsx <<'EOF'
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { authClient } from "@/lib/auth-client";
import { EmailCodeForm, buttonClass } from "@/app/components/email-code-form";

export function SignInForm() {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [useEmail, setUseEmail] = useState(false);
  const router = useRouter();
  function finish() { router.replace("/"); router.refresh(); }

  async function signIn() {
    setError("");
    if (!window.isSecureContext || !window.PublicKeyCredential) {
      setError("Passkeys require a supported browser using HTTPS or localhost. You can also use an email code.");
      return;
    }
    setPending(true);
    try {
      const result = await authClient.signIn.passkey();
      if (result.error || !result.data) {
        setError(result.error?.message ?? "Sign-in was cancelled. Please try again.");
        return;
      }
      finish();
    } catch { setError("Unable to sign in. Please try again."); }
    finally { setPending(false); }
  }

  return <div className="mt-6 space-y-4">
    {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
    <button type="button" onClick={signIn} disabled={pending} className={buttonClass}>
      {pending ? "Signing in..." : "Sign in with a passkey"}
    </button>
    <button type="button" disabled={pending} onClick={() => setUseEmail(!useEmail)} className="text-sm text-zinc-600">
      {useEmail ? "Hide email sign-in" : "Lost your passkey? Use an email code"}
    </button>
    {useEmail && <EmailCodeForm onVerified={finish} />}
  </div>;
}
EOF

echo "Writing app/signup/page.tsx..."
cat > app/signup/page.tsx <<'EOF'
import { auth } from "@/lib/auth";
import { headers } from "next/headers";
import Link from "next/link";
import { SignUpForm } from "./signup-form";

export default async function SignUpPage() {
  const session = await auth.api.getSession({ headers: await headers() });
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-6 text-zinc-950">
      <section className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-8 shadow-sm">
        <p className="text-sm font-medium text-zinc-500">Create an account</p>
        <h1 className="mt-3 text-3xl font-semibold">Sign up</h1>

        <SignUpForm verifiedEmail={session?.user.emailVerified ? session.user.email : undefined} />

        <Link
          href="/"
          className="mt-6 inline-flex text-sm font-medium text-zinc-600 hover:text-zinc-950"
        >
          Back home
        </Link>
      </section>
    </main>
  );
}
EOF

echo "Writing app/signup/signup-form.tsx..."
cat > app/signup/signup-form.tsx <<'EOF'
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { authClient } from "@/lib/auth-client";
import { EmailCodeForm, buttonClass } from "@/app/components/email-code-form";

export function SignUpForm({ verifiedEmail }: { verifiedEmail?: string }) {
  const [email, setEmail] = useState(verifiedEmail);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const router = useRouter();

  async function createPasskey() {
    setError("");
    if (!window.isSecureContext || !window.PublicKeyCredential) {
      setError("Passkeys require a supported browser using HTTPS or localhost.");
      return;
    }
    setPending(true);
    try {
      const result = await authClient.passkey.addPasskey({ name: "Monopopoly passkey" });
      if (result.error || !result.data) {
        setError(result.error?.message ?? "Passkey creation was cancelled. Please try again.");
        return;
      }
      router.replace("/");
      router.refresh();
    } catch { setError("Unable to create a passkey. Please try again."); }
    finally { setPending(false); }
  }

  if (!email) return <EmailCodeForm onVerified={setEmail} />;

  return <div className="mt-6 space-y-4">
    <p className="text-sm text-zinc-600">Email confirmed: {email}. Create a passkey to finish setting up your account.</p>
    <p className="text-sm text-zinc-600">Your device will ask you to use your fingerprint, face, PIN, or security key.</p>
    {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
    <button type="button" disabled={pending} onClick={createPasskey} className={buttonClass}>
      {pending ? "Creating passkey..." : "Create passkey"}
    </button>
  </div>;
}
EOF

echo "Writing app/signedout/page.tsx..."
cat > app/signedout/page.tsx <<'EOF'
import { getCurrentUser } from "@/lib/users";
import Link from "next/link";

export default async function SignedOutPage() {
  const user = await getCurrentUser();
  const isSignedOut = user === null;

  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-6 text-zinc-950">
      <section className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-8 shadow-sm">
        <p className="text-sm font-medium text-zinc-500">
          {isSignedOut ? "Signed out" : "Sign out failed"}
        </p>
        <h1 className="mt-3 text-3xl font-semibold">
          {isSignedOut
            ? "You have been signed out."
            : "You are still signed in."}
        </h1>

        {!isSignedOut && (
          <p className="mt-4 text-sm text-zinc-700">
            We could not confirm that your session ended. Please try signing out
            again.
          </p>
        )}

        <Link
          href="/"
          className="mt-6 inline-flex rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800"
        >
          Back home
        </Link>
      </section>
    </main>
  );
}
EOF

echo "Writing docker-compose.yml..."
cat > docker-compose.yml <<EOF
services:
  mysql:
    image: mysql:8
    container_name: ${PROJECT_NAME}-dev
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_USER: myuser
      MYSQL_PASSWORD: mypass
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
      - ./init-db:/docker-entrypoint-initdb.d

volumes:
  mysql-data:
EOF

echo "Writing init-db/init.sql..."
cat > init-db/init.sql <<'EOF'
CREATE DATABASE IF NOT EXISTS app_dev;
CREATE DATABASE IF NOT EXISTS app_test;
CREATE DATABASE IF NOT EXISTS app_shadow;

GRANT ALL PRIVILEGES ON app_dev.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON app_test.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON app_shadow.* TO 'myuser'@'%';

FLUSH PRIVILEGES;
EOF

echo "Writing lib/users.ts..."
cat > lib/users.ts <<'EOF'
"use server";

import { auth } from "@/lib/auth";
import { prisma } from "@/lib/prisma";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import type { User as PrismaUser } from "../generated/prisma/client";

export type User = Omit<PrismaUser, "image"> & {
  image?: PrismaUser["image"];
};

export const signOut = async () => {
  await auth.api.signOut({
    headers: await headers(),
  });
};

export const getCurrentUser = async (): Promise<User | null> => {
  const session = await auth.api.getSession({
    headers: await headers(),
  });

  if (!session) {
    return null;
  }

  const passkey = session.user.emailVerified
    ? await prisma.passkey.findFirst({
        where: { userId: session.user.id },
        select: { id: true },
      })
    : null;

  if (!passkey) {
    redirect("/signup");
  }

  return session.user as User;
};

export const requireUser = async (): Promise<User> => {
  const user = await getCurrentUser();

  if (!user) {
    redirect("/");
  }

  return user;
};
EOF

echo "Writing lib/utils.ts..."
cat > lib/utils.ts <<'EOF'
type InitialFormData<T> = T extends object ? Partial<T> : undefined;

export type FormState<T> =
  | {
      status: "initial";
      data?: InitialFormData<T>;
    }
  | {
      status: "success";
      data: T;
    }
  | {
      status: "error";
      data: T;
      errors: {
        formErrors: string[];
        fieldErrors?: Partial<Record<keyof T, string[]>>;
      };
    };
EOF

echo "Writing lib/auth-client.ts"
cat > lib/auth-client.ts <<'EOF'
import { createAuthClient } from "better-auth/react";
import { emailOTPClient } from "better-auth/client/plugins";
import { passkeyClient } from "@better-auth/passkey/client";

export const authClient = createAuthClient({
  plugins: [emailOTPClient(), passkeyClient()],
});
EOF

echo "Writing lib/email.ts"
cat > lib/email.ts <<'EOF'
import { Resend } from "resend";

export async function sendVerificationCode(email: string, otp: string) {
  if (process.env.NODE_ENV !== "production") {
    console.info(`[auth] Verification code for ${email}: ${otp}`);
    return;
  }

  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.RESEND_FROM_EMAIL;
  if (!apiKey || !from) {
    throw new Error("RESEND_API_KEY and RESEND_FROM_EMAIL are required in production");
  }

  const { error } = await new Resend(apiKey).emails.send({
    from,
    to: email,
    subject: "Your Monopopoly verification code",
    text: `Your verification code is ${otp}. It expires in 5 minutes. If you did not request this code, you can ignore this email.`,
  });
  if (error) throw new Error("Unable to send verification email");
}
EOF

echo "Writing lib/actions/signout.ts..."
cat > lib/actions/signout.ts <<'EOF'
"use server";

import { signOut } from "@/lib/users";
import { redirect } from "next/navigation";

export async function SignOutAction() {
    await signOut();
    redirect("/signedout");
}
EOF

echo "Starting MySQL with Docker Compose..."
docker compose up -d

echo "Generating Better Auth Prisma schema..."
npx auth@latest generate --yes

echo "Generating Prisma client..."
npx prisma generate

echo "Writing Prettier configuration..."
cat > .prettierrc <<'EOF'
{
  "tabWidth": 2,
  "semi": true
}
EOF

echo "Writing VS Code extension recommendations..."
mkdir -p .vscode
cat > .vscode/extensions.json <<'EOF'
{
  // See https://go.microsoft.com/fwlink/?LinkId=827846 to learn about workspace recommendations.
  // Extension identifier format: ${publisher}.${name}. Example: vscode.csharp

  // List of extensions which should be recommended for users of this workspace.
  "recommendations": [
    "Prisma.prisma",
    "esbenp.prettier-vscode",
    "openai.chatgpt"
  ],
  // List of extensions recommended by VS Code that should not be recommended for users of this workspace.
  "unwantedRecommendations": []
}
EOF

echo "Formatting project with Prettier..."
npx prettier --write .

if [ ! -d .git ]; then
  echo "Initializing git repository..."
  git init
fi

echo "Creating initial commit..."
git add .
git commit -m "Initial project setup"

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "1. Check prisma/schema.prisma and add or verify your models."
echo "2. Run:"
echo ""
echo "   npx prisma migrate dev --name init"
echo "   npx prisma generate"
echo "   npm run dev"
echo ""
echo "To delete the database later, run:"
echo ""
echo "   docker compose down -v"

