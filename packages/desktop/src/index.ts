export { buildReadinessReport, readinessColor } from "./readiness/map";
export {
  EDUCATED_PERMISSION_IDS,
  permissionEducation,
  permissionSetupState,
} from "./permissions/education";
export type { PermissionToGrant, PermissionSetupState } from "./permissions/education";
export {
  planPermissionOnboarding,
  REQUESTABLE_PERMISSION_IDS,
  MANUAL_PERMISSION_IDS,
  RESTART_REQUIRED_PERMISSION_IDS,
  ONBOARDING_PERMISSION_IDS,
} from "./permissions/onboarding";
export type { OnboardingStep, OnboardingPlan, PermissionAction } from "./permissions/onboarding";
