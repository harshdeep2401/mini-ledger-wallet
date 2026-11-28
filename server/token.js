// The session token travels as "Authorization: Bearer <token>". The server never
// decides who the caller is: it passes the token to a database function that checks it.
export const tokenOf = (req) => req.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
