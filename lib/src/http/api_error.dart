/// An error the API reports to the client with a status code and a stable,
/// machine-readable [code].
///
/// Handlers throw these; the error middleware turns them into
/// `{"error": {"code": ..., "message": ..., "details": ...}}` responses.
class ApiError implements Exception {
  ApiError(this.status, this.code, this.message, {this.details});

  /// 400: the request is malformed or a field is invalid.
  factory ApiError.badRequest(String message, {Object? details}) =>
      ApiError(400, 'bad_request', message, details: details);

  /// 401: no valid session.
  factory ApiError.unauthenticated([String message = 'Sign in to continue']) =>
      ApiError(401, 'unauthenticated', message);

  /// 403: signed in and allowed to see the resource, but not to do this.
  factory ApiError.forbidden(String message) =>
      ApiError(403, 'forbidden', message);

  /// 404: the resource does not exist, or the caller may not know it exists.
  factory ApiError.notFound([String message = 'Not found']) =>
      ApiError(404, 'not_found', message);

  /// 409: the request is valid but conflicts with the current state.
  factory ApiError.conflict(String code, String message, {Object? details}) =>
      ApiError(409, code, message, details: details);

  final int status;
  final String code;
  final String message;
  final Object? details;

  Map<String, Object?> toJson() => {
    'error': {
      'code': code,
      'message': message,
      if (details != null) 'details': details,
    },
  };

  @override
  String toString() => 'ApiError($status $code: $message)';
}
