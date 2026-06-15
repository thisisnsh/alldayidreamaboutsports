type Severity = "DEBUG" | "INFO" | "WARNING" | "ERROR";

function write(severity: Severity, message: string, fields: Record<string, unknown> = {}): void {
  const entry = JSON.stringify({ severity, message, ...fields });
  if (severity === "ERROR") console.error(entry);
  else if (severity === "WARNING") console.warn(entry);
  else console.log(entry);
}

export const log = {
  debug: (message: string, fields?: Record<string, unknown>) => write("DEBUG", message, fields),
  info: (message: string, fields?: Record<string, unknown>) => write("INFO", message, fields),
  warning: (message: string, fields?: Record<string, unknown>) => write("WARNING", message, fields),
  error: (message: string, error: unknown, fields: Record<string, unknown> = {}) =>
    write("ERROR", message, {
      ...fields,
      error: error instanceof Error ? error.message : String(error),
      ...(error instanceof Error && error.stack ? { stack: error.stack } : {}),
    }),
};
