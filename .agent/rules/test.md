---
trigger: always_on
---

# Agent Rules
## Build Logging and Output
- **Rule**: Any build process (specifically **Flutter build** or Gradle build) MUST have its output saved to a log file use utf 8 format for saving the text.
- **Filename Format**: `build_<timestamp>.txt` (e.g., `build_20240101_120000.t`).
- **Target Directory**: `D:\Repos\passwordpdf\logs`
  > **Note**: If `D:\Repos\passwordpdf\logs` is not accessible in the current workspace, use the `logs/` directory in the project root.
## Workflow
- When asked to build, log them to a file in logs folder with filename build_<timestamp>.txt