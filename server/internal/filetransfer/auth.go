package filetransfer

import (
	"context"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
)

type ctxKey int

const claimsKey ctxKey = iota

// TokenParser validates an access token.
type TokenParser interface {
	Parse(token string) (*auth.Claims, error)
}

// TokenChecker reports whether a token is still current for its user/device.
type TokenChecker interface {
	TokenVersion(ctx context.Context, userID, deviceID [16]byte) (int, bool, error)
}

// ClaimsFrom retrieves the authenticated claims from a gRPC context.
func ClaimsFrom(ctx context.Context) (*auth.Claims, bool) {
	c, ok := ctx.Value(claimsKey).(*auth.Claims)
	return c, ok
}

// UnaryAuthInterceptor authenticates unary calls.
func UnaryAuthInterceptor(parser TokenParser, checker TokenChecker) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req any,
		_ *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (any, error) {
		authed, err := authenticate(ctx, parser, checker)
		if err != nil {
			return nil, err
		}
		return handler(authed, req)
	}
}

// StreamAuthInterceptor authenticates streaming calls.
//
// Uploads and downloads are streams, so without this they would be the one
// unauthenticated surface on the server.
func StreamAuthInterceptor(parser TokenParser, checker TokenChecker) grpc.StreamServerInterceptor {
	return func(
		srv any,
		ss grpc.ServerStream,
		_ *grpc.StreamServerInfo,
		handler grpc.StreamHandler,
	) error {
		authed, err := authenticate(ss.Context(), parser, checker)
		if err != nil {
			return err
		}
		return handler(srv, &wrappedStream{ServerStream: ss, ctx: authed})
	}
}

// authenticate validates the bearer token carried in call metadata.
func authenticate(
	ctx context.Context,
	parser TokenParser,
	checker TokenChecker,
) (context.Context, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing metadata")
	}

	values := md.Get("authorization")
	if len(values) == 0 {
		return nil, status.Error(codes.Unauthenticated, "missing authorization")
	}

	const prefix = "Bearer "
	raw := values[0]
	if len(raw) <= len(prefix) || !strings.EqualFold(raw[:len(prefix)], prefix) {
		return nil, status.Error(codes.Unauthenticated, "malformed authorization")
	}

	claims, err := parser.Parse(strings.TrimSpace(raw[len(prefix):]))
	if err != nil {
		return nil, status.Error(codes.Unauthenticated, "invalid token")
	}

	// A valid signature is not sufficient: the token must still be current for
	// this user, and the device must not have been revoked. Otherwise a signed
	// -out device could keep uploading until its token expired.
	if checker != nil {
		version, active, err := checker.TokenVersion(ctx, claims.UserID, claims.DeviceID)
		if err != nil || !active || version != claims.TokenVer {
			return nil, status.Error(codes.Unauthenticated, "invalid token")
		}
	}

	return context.WithValue(ctx, claimsKey, claims), nil
}

// wrappedStream carries the authenticated context through a stream, since
// grpc.ServerStream exposes its context read-only.
type wrappedStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (w *wrappedStream) Context() context.Context { return w.ctx }
