/**
 * A loggable summary of a provider's error response: the HTTP status plus the
 * provider's own error code and message. Never the raw body. Some bodies echo
 * generated text derived from the clip (Groq's failed JSON generations do), and
 * SceneFind tells users and App Review that shared content stays out of logs.
 */
export async function providerErrorSummary(response: Response): Promise<string> {
  let code = "";
  let message = "";
  try {
    const body = await response.json() as { error?: unknown };
    const error = body?.error;
    if (typeof error === "string") {
      message = error;
    } else if (error && typeof error === "object") {
      const fields = error as Record<string, unknown>;
      code = String(fields.code ?? fields.status ?? fields.type ?? "");
      message = typeof fields.message === "string" ? fields.message : "";
    }
  } catch {
    // Not JSON. The status alone has to do.
  }
  return `${response.status}${code ? ` ${code}` : ""}${message ? `: ${message.slice(0, 160)}` : ""}`;
}
