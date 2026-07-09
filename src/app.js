import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import { createHandler } from 'graphql-http/lib/use/express';
import { schema as graphqlSchema } from './graphql/schema.js';
import { verifyToken } from './config/jwt.js';
import errorMiddleware from './middlewares/error.middleware.js';

const app = express();

app.use(helmet());
app.use(morgan('combined'));

// Built-in fallback so a missing/misconfigured ALLOWED_ORIGINS on the host
// (e.g. Render's dashboard env, separate from this repo's .env) never
// silently CORS-blocks every browser request. ALLOWED_ORIGINS still adds to
// this, it just can't accidentally replace it with an empty list.
const DEFAULT_ALLOWED_ORIGINS = [
  'https://diwan-city-frontend.vercel.app',
  'http://localhost:5173',
  'http://localhost:5174',
];
const allowedOrigins = new Set([
  ...DEFAULT_ALLOWED_ORIGINS,
  ...(process.env.ALLOWED_ORIGINS || '').split(',').map((origin) => origin.trim()).filter(Boolean),
]);
// Vercel preview deployments (diwan-city-frontend-<hash>-<scope>.vercel.app)
// get a fresh URL per deploy, so they can't live in a static allowlist.
const VERCEL_PREVIEW_ORIGIN = /^https:\/\/diwan-city-frontend-[a-z0-9-]+\.vercel\.app$/;

app.use(cors({
  origin: (origin, callback) => {
    // Allow non-browser requests (curl, server-to-server, mobile apps) which send no Origin header
    if (!origin || allowedOrigins.has(origin) || VERCEL_PREVIEW_ORIGIN.test(origin)) {
      return callback(null, true);
    }
    return callback(new Error(`Not allowed by CORS: ${origin}`));
  },
  credentials: true,
}));
app.use(express.json({ limit: '25mb' }));
app.use(express.urlencoded({ extended: true, limit: '25mb' }));

import path from 'path';
// Serve fallback local excel files if AWS S3 isn't configured
app.use('/uploads/excel', express.static(path.join(process.cwd(), 'uploads', 'excel')));

// ── GraphQL endpoint (dashboard BFF) ──
app.all('/graphql', createHandler({
  schema: graphqlSchema,
  context: (req) => {
    // Extract JWT from Authorization header for GraphQL context
    const token = req.raw.headers.authorization?.replace('Bearer ', '');
    let user = null;
    if (token) {
      try { user = verifyToken(token); } catch { /* unauthenticated */ }
    }
    return { user };
  },
}));

// routes
import indexRoutes from './routes/index.js';
app.use('/', indexRoutes);

// error middleware
app.use(errorMiddleware);

export default app;