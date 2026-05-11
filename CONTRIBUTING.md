# Contributing to MSP Script Library

Thank you for contributing! This repository uses branch protection to ensure all changes are reviewed before reaching production.

## Quick Start

1. **Create an enhancement or problem branch:**
   ```bash
   git checkout -b enhancement/your-enhancement-name
   # or for bug fixes:
   git checkout -b problem/issue-description
   ```

2. **Make your changes and commit:**
   ```bash
   git add .
   git commit -m "Description of changes"
   ```

3. **Push your branch:**
   ```bash
   git push -u origin enhancement/your-enhancement-name
   ```

4. **Create a Pull Request:**
   - Go to https://github.com/dtc-inc/msp-script-library
   - Click "Pull requests" → "New pull request"
   - Select your branch and create the PR
   - Nate (@Gumbees) will automatically be assigned for review

5. **Wait for review approval** before merging

## Important Rules

- ❌ **Never commit directly to `main`** - Branch protection prevents this
- ✅ **All changes require a Pull Request**
- ✅ **All PRs require approval from @Gumbees before merging**
- ✅ **Test your scripts in both interactive and RMM modes before submitting**

## Branch Naming Convention

- `enhancement/` - New features, improvements, or enhancements
- `problem/` - Bug fixes, hotfixes, or any issue resolution

Examples:
- `enhancement/admin-user-180day-deletion`
- `problem/iso-dismount-error`
- `problem/script-hanging-rmm`

## Script Standards

- Use the template from `script-template-powershell.ps1`
- Follow the three-section structure (RMM Variables → Input Handling → Script Logic)
- Support both RMM and interactive execution modes
- Include full logging with `Start-Transcript` / `Stop-Transcript`

See **CLAUDE.md** for detailed development standards and patterns.

## Need Help?

- Check **CLAUDE.md** for technical details
- Ask Nate (@Gumbees) for guidance
- Reference existing scripts for patterns
