import type { NextFunction, Response } from 'express';
import {
  buildOAuthFailureLog,
  isOAuthProtocolFailure,
  type OAuthFailureLog,
  type OAuthFailureRequest,
} from './failure';

type LoginFunction = (
  user: unknown,
  options: { session: false },
  done: (err?: unknown) => void,
) => void;

export type OpenIDCallbackRequest = OAuthFailureRequest & {
  logIn?: LoginFunction;
  user?: unknown;
};

type OpenIDCallback = (err: unknown, user: unknown, info: unknown) => void;

type PassportMiddleware = (
  req: OpenIDCallbackRequest,
  res: Response,
  next: NextFunction,
) => unknown;

type PassportLike = {
  authenticate: (
    strategy: 'openid',
    options: {
      failureMessage: true;
      session: false;
    },
    callback: OpenIDCallback,
  ) => PassportMiddleware;
};

type OAuthCallbackLogLevel = 'warn' | 'error';

type OAuthCallbackLogger = Record<
  OAuthCallbackLogLevel,
  (message: string, details: OAuthFailureLog) => void
>;

export type AuthFailureRedirectOptions = {
  clientDomain?: string;
  authFailedError: string;
};

export type LogOpenIDCallbackFailureOptions = {
  logger: OAuthCallbackLogger;
  req: OAuthFailureRequest;
  err?: unknown;
  info?: unknown;
  level?: OAuthCallbackLogLevel;
};

export type OpenIDCallbackAuthenticatorOptions = AuthFailureRedirectOptions & {
  logger: OAuthCallbackLogger;
  passport: PassportLike;
};

export function redirectToAuthFailure(
  res: Response,
  { clientDomain, authFailedError }: AuthFailureRedirectOptions,
): void {
  res.redirect(`${clientDomain}/login?redirect=false&error=${authFailedError}`);
}

/**
 * The identity provider's own reason for rejecting the callback arrives as the
 * `error`/`error_description` query pair and is the only thing that identifies
 * a misconfiguration (an unconsented scope, a tenant restriction). It is
 * folded into the message text because the winston formatter prints the
 * message and drops the rest of the details object, which left the failure
 * logged as a bare "authorization response from the server is an error".
 */
function describeProviderRejection(details: OAuthFailureLog): string {
  if (!details.query_error) {
    return '';
  }
  if (!details.query_error_description) {
    return ` [provider: ${details.query_error}]`;
  }
  return ` [provider: ${details.query_error} - ${details.query_error_description}]`;
}

export function logOpenIDCallbackFailure({
  logger,
  req,
  err,
  info,
  level = 'warn',
}: LogOpenIDCallbackFailureOptions): void {
  const details = buildOAuthFailureLog({
    provider: 'openid',
    req,
    err,
    info,
    defaultMessage: 'OpenID authentication failed',
  });
  const prefix =
    level === 'error'
      ? '[OpenID OAuth] Callback authentication error'
      : '[OpenID OAuth] Callback authentication failed';
  logger[level](`${prefix}${describeProviderRejection(details)}`, details);
}

export function createOpenIDCallbackAuthenticator({
  passport,
  logger,
  clientDomain,
  authFailedError,
}: OpenIDCallbackAuthenticatorOptions): (
  req: OpenIDCallbackRequest,
  res: Response,
  next: NextFunction,
) => unknown {
  return (req: OpenIDCallbackRequest, res: Response, next: NextFunction): unknown => {
    return passport.authenticate(
      'openid',
      {
        failureMessage: true,
        session: false,
      },
      (err: unknown, user: unknown, info: unknown) => {
        if (err) {
          if (isOAuthProtocolFailure(err, info)) {
            logOpenIDCallbackFailure({ logger, req, err, info });
            return redirectToAuthFailure(res, { clientDomain, authFailedError });
          }

          logOpenIDCallbackFailure({ logger, req, err, info, level: 'error' });
          return next(err);
        }

        if (!user) {
          logOpenIDCallbackFailure({ logger, req, err, info });
          return redirectToAuthFailure(res, { clientDomain, authFailedError });
        }

        if (typeof req.logIn !== 'function') {
          req.user = user;
          return next();
        }

        return req.logIn(user, { session: false }, (loginErr?: unknown) => {
          if (loginErr) {
            logOpenIDCallbackFailure({ logger, req, err: loginErr, info, level: 'error' });
            return next(loginErr);
          }
          return next();
        });
      },
    )(req, res, next);
  };
}
