#!/usr/bin/env bash

# bash <(curl -fsSL https://gist.githubusercontent.com/PeterHedemann/5e9c4e700288d00fe8bf772a87749fa5/raw) {foldername}

set -euo pipefail

PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: ./setup-next-better-auth.sh <project-folder>"
  exit 1
fi

echo "Creating project in: $PROJECT_DIR"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

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
npm install @prisma/client@7 @prisma/adapter-mariadb@7 dotenv better-auth @better-auth/prisma-adapter zod

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
EOF

echo "Writing .env.example..."
cat > .env.example <<EOF
BETTER_AUTH_SECRET=<your-secret-here>
BETTER_AUTH_URL=http://localhost:3000
DATABASE_URL="mysql://myuser:mypass@127.0.0.1:3306/app_dev"
SHADOW_DATABASE_URL="mysql://myuser:mypass@127.0.0.1:3306/app_shadow"
NODE_ENV="development"
PORT=3000
EOF

echo "Creating folders..."
mkdir -p lib
mkdir -p lib/actions
mkdir -p app/api/auth/[...all]
mkdir -p app/signin
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
import { prisma } from "./prisma";

export const auth = betterAuth({
  database: prismaAdapter(prisma, {
    provider: "mysql",
  }),
  emailAndPassword: {
    enabled: true,
  },
  plugins: [nextCookies()],
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

import { useActionState } from "react";
import { SignInAction, type SignInFormData } from "@/lib/actions/signin";
import type { FormState } from "@/lib/utils";

const initialState: FormState<SignInFormData> = {
  status: "initial",
};

export function SignInForm() {
  const [state, formAction, pending] = useActionState(
    SignInAction,
    initialState,
  );

  const formErrors = state.status === "error" ? state.errors.formErrors : [];
  const fieldErrors =
    state.status === "error" ? state.errors.fieldErrors : undefined;

  return (
    <form action={formAction} className="mt-6 space-y-4">
      {formErrors.length > 0 && (
        <div
          aria-live="polite"
          className="rounded-md bg-red-50 p-3 text-sm text-red-700"
        >
          {formErrors.map((error) => (
            <p key={error}>{error}</p>
          ))}
        </div>
      )}

      <label className="block text-sm font-medium">
        Email
        <input
          name="email"
          type="email"
          required
          defaultValue={state.data?.email}
          aria-invalid={Boolean(fieldErrors?.email)}
          aria-describedby={fieldErrors?.email ? "email-error" : undefined}
          className="mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950"
        />
      </label>
      {fieldErrors?.email && (
        <p id="email-error" className="-mt-2 text-sm text-red-700">
          {fieldErrors.email[0]}
        </p>
      )}

      <label className="block text-sm font-medium">
        Password
        <input
          name="password"
          type="password"
          required
          aria-invalid={Boolean(fieldErrors?.password)}
          aria-describedby={
            fieldErrors?.password ? "password-error" : undefined
          }
          className="mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950"
        />
      </label>
      {fieldErrors?.password && (
        <p id="password-error" className="-mt-2 text-sm text-red-700">
          {fieldErrors.password[0]}
        </p>
      )}

      <button
        type="submit"
        disabled={pending}
        className="w-full rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:cursor-not-allowed disabled:bg-zinc-500"
      >
        {pending ? "Signing in..." : "Sign in"}
      </button>
    </form>
  );
}
EOF

echo "Writing app/signup/page.tsx..."
cat > app/signup/page.tsx <<'EOF'
import Link from "next/link";
import { SignUpForm } from "./signup-form";

export default function SignUpPage() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-6 text-zinc-950">
      <section className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-8 shadow-sm">
        <p className="text-sm font-medium text-zinc-500">Create an account</p>
        <h1 className="mt-3 text-3xl font-semibold">Sign up</h1>

        <SignUpForm />

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

import { useActionState } from "react";
import { SignUpAction, type SignUpFormData } from "@/lib/actions/signup";
import type { FormState } from "@/lib/utils";

const initialState: FormState<SignUpFormData> = {
  status: "initial",
};

export function SignUpForm() {
  const [state, formAction, pending] = useActionState(
    SignUpAction,
    initialState,
  );

  const formErrors = state.status === "error" ? state.errors.formErrors : [];
  const fieldErrors =
    state.status === "error" ? state.errors.fieldErrors : undefined;

  return (
    <form action={formAction} className="mt-6 space-y-4">
      {formErrors.length > 0 && (
        <div
          aria-live="polite"
          className="rounded-md bg-red-50 p-3 text-sm text-red-700"
        >
          {formErrors.map((error) => (
            <p key={error}>{error}</p>
          ))}
        </div>
      )}

      <label className="block text-sm font-medium">
        Name
        <input
          name="name"
          type="text"
          required
          defaultValue={state.data?.name}
          aria-invalid={Boolean(fieldErrors?.name)}
          aria-describedby={fieldErrors?.name ? "name-error" : undefined}
          className="mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950"
        />
      </label>
      {fieldErrors?.name && (
        <p id="name-error" className="-mt-2 text-sm text-red-700">
          {fieldErrors.name[0]}
        </p>
      )}

      <label className="block text-sm font-medium">
        Email
        <input
          name="email"
          type="email"
          required
          defaultValue={state.data?.email}
          aria-invalid={Boolean(fieldErrors?.email)}
          aria-describedby={fieldErrors?.email ? "email-error" : undefined}
          className="mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950"
        />
      </label>
      {fieldErrors?.email && (
        <p id="email-error" className="-mt-2 text-sm text-red-700">
          {fieldErrors.email[0]}
        </p>
      )}

      <label className="block text-sm font-medium">
        Password
        <input
          name="password"
          type="password"
          required
          aria-invalid={Boolean(fieldErrors?.password)}
          aria-describedby={
            fieldErrors?.password ? "password-error" : undefined
          }
          className="mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950"
        />
      </label>
      {fieldErrors?.password && (
        <p id="password-error" className="-mt-2 text-sm text-red-700">
          {fieldErrors.password[0]}
        </p>
      )}

      <label className="block text-sm font-medium">
        Repeat password
        <input
          name="repeatPassword"
          type="password"
          required
          aria-invalid={Boolean(fieldErrors?.repeatPassword)}
          aria-describedby={
            fieldErrors?.repeatPassword ? "repeat-password-error" : undefined
          }
          className="mt-2 w-full rounded-md border border-zinc-300 px-3 py-2 text-sm outline-none focus:border-zinc-950"
        />
      </label>
      {fieldErrors?.repeatPassword && (
        <p id="repeat-password-error" className="-mt-2 text-sm text-red-700">
          {fieldErrors.repeatPassword[0]}
        </p>
      )}

      <button
        type="submit"
        disabled={pending}
        className="w-full rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:cursor-not-allowed disabled:bg-zinc-500"
      >
        {pending ? "Creating account..." : "Create account"}
      </button>
    </form>
  );
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
    container_name: ${PROJECT_DIR}-dev
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
import { APIError } from "better-auth/api";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import type { User as PrismaUser } from "../generated/prisma/client";

export type User = Omit<PrismaUser, "image"> & {
  image?: PrismaUser["image"];
};

export type Error = {
  message: string;
};

export type Result<T> =
  | { success: true; data: T }
  | { success: false; message: string };

export const signIn = async (
  email: string,
  password: string
): Promise<Result<User>> => {
  try {
    const { user } = await auth.api.signInEmail({
      body: { email, password },
    });

    return { success: true, data: user as User };
  } catch (error) {
    console.error("Error signing in:", error);

    return {
      success: false,
      message: "Invalid email or password.",
    };
  }
};

export const signOut = async () => {
  await auth.api.signOut({
    headers: await headers(),
  });
};

export const signUp = async (
  name: string,
  email: string,
  password: string
): Promise<Result<User>> => {
  try {
    const { user } = await auth.api.signUpEmail({
      body: { name, email, password },
    });

    return { success: true, data: user as User };
  } catch (error) {
    if (error instanceof APIError) {
      console.log("API Error:", error.message);

      return {
        success: false,
        message: error.message,
      };
    }

    return {
      success: false,
      message: "Error signing up",
    };
  }
};

export const getCurrentUser = async (): Promise<User | null> => {
  const session = await auth.api.getSession({
    headers: await headers(),
  });

  if (!session) {
    return null;
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

echo "Writing lib/actions/signin.ts..."
cat > lib/actions/signin.ts <<'EOF'
"use server";

import { signIn } from "@/lib/users";
import { redirect } from "next/navigation";
import { FormState } from "../utils";
import * as z from "zod";

const SignInSchema = z.object({
    email: z.email(),
    password: z.string("Password is required").min(8, "Password is at least 8 characters")
});

export type SignInFormData = z.infer<typeof SignInSchema>;

export async function SignInAction(
    prevState: FormState<SignInFormData>,
    formData: FormData
): Promise<FormState<SignInFormData>> {
    const email = formData.get("email") as string;
    const password = formData.get("password") as string;

    const data = {email, password};

    const parsedData = SignInSchema.safeParse(data);

    if(!parsedData.success) {
        const errors = z.flattenError(parsedData.error)
        return { status: "error", data, errors };
    }
    const result = await signIn(email, password);
    
    if (result.success) {
        redirect("/");
    }

    return { status: "error", data, errors: {formErrors: [result.message]}}
}
EOF

echo "Writing lib/actions/signup.ts..."
cat > lib/actions/signup.ts <<'EOF'
"use server";

import { signUp } from "@/lib/users";
import { redirect } from "next/navigation";
import { FormState } from "../utils";
import * as z from "zod";

const SignUpSchema = z.object({
    name: z.string().trim().min(1, "Name is required"),
    email: z.email("Email is required"),
    password: z.string("Password is required").min(8, "Password should be at least 8 characters"),
    repeatPassword: z.string("Please repeat your chosen password"),
}).refine((data) => data.password === data.repeatPassword, {
    message: "Passwords don't match",
    path: ["repeatPassword"],
});

export type SignUpFormData = z.infer<typeof SignUpSchema>;

export async function SignUpAction(
    prevState: FormState<SignUpFormData>,
    formData: FormData
): Promise<FormState<SignUpFormData>> {
    const name = formData.get("name") as string;
    const email = formData.get("email") as string;
    const password = formData.get("password") as string;
    const repeatPassword = formData.get("repeatPassword") as string;

    const data = { name, email, password, repeatPassword }
    const parsedData = SignUpSchema.safeParse(data);

    if (!parsedData.success) {
        const errors = z.flattenError(parsedData.error);
        return { status: "error", data, errors }
    }

    const result = await signUp(name, email, password);
    
    if (result.success) {
        redirect("/");
    } else {
        return { status: "error", data, errors: { formErrors: [result.message] } };
    }
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
