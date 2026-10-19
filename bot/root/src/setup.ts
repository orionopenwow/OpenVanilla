// Builds (or tops up) the Open Vanilla community on Root from layout.ts. Safe to re-run: it only adds
// what's missing (matched by name) and never deletes or renames anything you made yourself.
import {
  rootServer, ChannelType, WellKnownRootGuids, RootApiException, MessageDirectionTake,
  CommunityRole, ChannelGroup, Channel, CommunityPermission, ChannelOverlayPermission,
  AccessRuleCreateRoleOrMemberRequest, RoleOrMemberGuid, ChannelGuid,
} from "@rootsdk/server-bot";
import { ROLES, STAFF, TESTERS, LAYOUT, POSTS, COMMUNITY_NAME, COMMUNITY_DESCRIPTION, Audience, Kind } from "./layout";

const log = (...a: unknown[]) => console.log("[Open Vanilla setup]", ...a);
const err = (what: string, e: unknown) =>
  console.error("[Open Vanilla setup] FAILED:", what, "->", e instanceof RootApiException ? `RootApiException ${e.errorCode}` : e instanceof Error ? e.message : e);
const norm = (s: string) => s.trim().toLowerCase();

const NO_COMMUNITY: CommunityPermission = {
  communityManageCommunity: false, communityManageRoles: false, communityManageEmojis: false, communityManageAuditLog: false,
  communityCreateInvite: false, communityManageInvites: false, communityCreateBan: false, communityManageBans: false,
  communityFullControl: false, communityKick: false, communityChangeMyNickname: false, communityChangeOtherNickname: false,
  communityCreateChannelGroup: false, communityManageApps: false,
};
function communityPerms(staff?: "admin" | "mod"): CommunityPermission | undefined {
  if (staff === "admin") return { ...NO_COMMUNITY, communityFullControl: true, communityChangeMyNickname: true };
  if (staff === "mod") return { ...NO_COMMUNITY, communityKick: true, communityCreateBan: true, communityManageBans: true,
    communityCreateInvite: true, communityManageInvites: true, communityChangeMyNickname: true, communityChangeOtherNickname: true,
    communityManageAuditLog: true };
  return undefined; // badge and pick-your-own roles: no extra powers
}
const MOD_CHANNEL: ChannelOverlayPermission = {
  channelView: true, channelViewMessageHistory: true, channelCreateMessage: true, channelDeleteMessageOther: true,
  channelManagePinnedMessages: true, channelVoiceMuteOther: true, channelVoiceKick: true, channelMoveUserOther: true,
};
const asRule = (id: string) => id as unknown as RoleOrMemberGuid;

export async function runSetup(): Promise<void> {
  log("starting");
  const summary = { roles: 0, groups: 0, channels: 0, posts: 0, failed: 0 };

  // 1. community name and description
  try {
    const c = await rootServer.community.communities.get();
    if (c.name !== COMMUNITY_NAME || (c.description ?? "") !== COMMUNITY_DESCRIPTION) {
      await rootServer.community.communities.edit({
        name: COMMUNITY_NAME, description: COMMUNITY_DESCRIPTION, pictureHex: c.pictureHex, updatePicture: false,
        defaultChannelId: c.defaultChannelId, rejectUnverifiedEmail: c.rejectUnverifiedEmail, joinThrottle: c.joinThrottle,
        isAgeRestricted: c.isAgeRestricted,
      });
      log(`community named "${COMMUNITY_NAME}"`);
    }
  } catch (e) { summary.failed++; err("community name/description", e); }

  // 2. roles
  const roles = new Map<string, CommunityRole>();
  try { for (const r of await rootServer.community.communityRoles.list()) roles.set(norm(r.name), r); }
  catch (e) { summary.failed++; err("list roles", e); }
  for (const def of ROLES) {
    if (roles.has(norm(def.name))) continue;
    try {
      const r = await rootServer.community.communityRoles.create({
        name: def.name, colorHex: def.color, isMentionable: !!def.staff || def.name === "Adventurer", isSelfAssignable: !!def.self,
        communityPermission: communityPerms(def.staff),
      });
      roles.set(norm(def.name), r); summary.roles++; log("role", def.name);
    } catch (e) { summary.failed++; err(`role ${def.name}`, e); }
  }
  const ids = (names: string[]) => names.map((n) => roles.get(norm(n))?.id).filter((x): x is CommunityRole["id"] => !!x);
  const everyone = WellKnownRootGuids.CommunityRoles.EveryoneRole;

  // access rules for an audience (Root keeps an access list per group or channel)
  function rules(aud: Audience): AccessRuleCreateRoleOrMemberRequest[] {
    const staff = ids(STAFF).map((id) => ({ roleOrMemberId: asRule(id), overlay: MOD_CHANNEL }));
    switch (aud) {
      case "everyone": return [{ roleOrMemberId: asRule(everyone) }, ...staff];
      case "readonly": return [{ roleOrMemberId: asRule(everyone), overlay: { channelView: true, channelViewMessageHistory: true,
        channelCreateMessage: false, channelCreateMessageReaction: true } }, ...staff];
      case "testers": return [...ids(TESTERS).map((id) => ({ roleOrMemberId: asRule(id) })), ...staff];
      case "staff": return staff;
    }
  }
  const TYPE: Record<Kind, number> = { text: ChannelType.Text, threads: ChannelType.ThreadedText, voice: ChannelType.Voice };

  // 3. channel groups and channels
  let groups: ChannelGroup[] = [];
  try { groups = await rootServer.community.channelGroups.list(); } catch (e) { summary.failed++; err("list channel groups", e); }
  const created = new Map<string, ChannelGuid>(); // channel name -> id, for channels made in this run
  let welcomeId: ChannelGuid | undefined;
  for (const g of LAYOUT) {
    let group = groups.find((x) => norm(x.name) === norm(g.name));
    if (!group) {
      try {
        group = await rootServer.community.channelGroups.create({ name: g.name, accessRuleCreates: rules(g.audience) });
        groups.push(group); summary.groups++; log("group", g.name);
      } catch (e) { summary.failed++; err(`group ${g.name}`, e); continue; }
    }
    let existing: Channel[] = [];
    try { existing = await rootServer.community.channels.list({ channelGroupId: group.id }); } catch (e) { err(`list channels in ${g.name}`, e); }
    for (const c of g.channels) {
      const have = existing.find((x) => norm(x.name) === norm(c.name));
      if (have) { if (c.name === "welcome") welcomeId = have.id; continue; }
      const own = c.audience && c.audience !== g.audience;
      try {
        const ch = await rootServer.community.channels.create({
          channelGroupId: group.id, name: c.name, description: c.topic || undefined, channelType: TYPE[c.kind],
          useChannelGroupPermission: !own, accessRuleCreates: own ? rules(c.audience!) : undefined,
        });
        created.set(c.name, ch.id); summary.channels++; log("channel", `${g.name} / ${c.name}`);
        if (c.name === "welcome") welcomeId = ch.id;
      } catch (e) { summary.failed++; err(`channel ${c.name}`, e); }
    }
  }

  // 4. the bot's info posts (skipped where a post with the same title is already there)
  const allChannels = new Map<string, ChannelGuid>();
  for (const g of groups) {
    try { for (const c of await rootServer.community.channels.list({ channelGroupId: g.id })) allChannels.set(norm(c.name), c.id); } catch { /* listed above */ }
  }
  for (const [name, text] of Object.entries(POSTS)) {
    const channelId = created.get(name) ?? allChannels.get(norm(name)); if (!channelId) continue;
    const title = text.split("\n", 1)[0];
    try {
      const recent = await rootServer.community.channelMessages.list({ channelId, messageDirectionTake: MessageDirectionTake.Older, dateAt: new Date(), limit: 50 });
      if (recent.messages.some((m) => (m.messageContent ?? "").startsWith(title))) continue;
      const m = await rootServer.community.channelMessages.create({ channelId, content: text });
      summary.posts++; log("post", name);
      try { await rootServer.community.channelMessages.pinCreate({ channelId, messageId: m.id }); } catch { /* pinning is a nicety */ }
    } catch (e) { summary.failed++; err(`post in ${name}`, e); }
  }

  // 5. members land in #welcome
  if (welcomeId) {
    try {
      const c = await rootServer.community.communities.get();
      if (c.defaultChannelId !== welcomeId) {
        await rootServer.community.communities.edit({ name: c.name, description: c.description, pictureHex: c.pictureHex, updatePicture: false,
          defaultChannelId: welcomeId, rejectUnverifiedEmail: c.rejectUnverifiedEmail, joinThrottle: c.joinThrottle, isAgeRestricted: c.isAgeRestricted });
        log("default channel set to welcome");
      }
    } catch (e) { summary.failed++; err("default channel", e); }
  }

  log(`DONE. Added ${summary.roles} roles, ${summary.groups} groups, ${summary.channels} channels, ${summary.posts} posts` +
      (summary.failed ? `; ${summary.failed} step(s) failed (see the FAILED lines above).` : ". Nothing failed."));
  log("You can close this window (Ctrl+C). Re-run any time; it only adds what's missing.");
}
