()
            PlaySound("igMainMenuOption")
            HideUIPanel(GameMenuFrame)
            BenillaAddonList_Show()
        end)

        GameMenuButtonLogout:SetPoint("TOP", addonsBtn, "BOTTOM", 0, -20)
        GameMenuButtonQuit:SetPoint("TOP", GameMenuButtonLogout, "BOTTOM", 0, 0)
        GameMenuButtonContinue:SetPoint("TOP", GameMenuButtonQuit, "BOTTOM", 0, -20)

        -- ââ Our options window in the stock "is an options window open?" checks âââââââââââââââ
        -- Each wraps the stock function to add `BenillaOptionsFrame` and `BenillaAddonListFrame`.
        local Ref_IsOptionFrameOpen = IsOptionFrameOpen
        local Ref_ToggleGameMenu = ToggleGameMenu
        local Ref_UpdateMicroButtons = UpdateMicroButtons

        -- Guarded for a test kit that loads the game menu without the options window.
        local function BenillaOptions_IsOpen()
            return (BenillaOptionsFrame and BenillaOptionsFrame:IsVisible())
                or (BenillaAddonListFrame and BenillaAddonListFrame:IsVisible())
        end

        -- `UIParent.lua:996`: a yes keeps the ESC sweep off the centre panel, which our window is.
        function IsOptionFrameOpen()
            if BenillaOptions_IsOpen() then
                return 1
            end
            return Ref_IsOptionFrameOpen()
        end

        -- `UIParent.lua:1465-1497`: static popup, then an open options window, then the stock
        -- ladder. Our Close click is the discard-and-hide of the reference's `OptionsFrameCancel`.
        function ToggleGameMenu(clicked)
            if clicked then
                -- As the reference's `clicked` arm: close an options window, then toggle.
                if BenillaOptions_IsOpen() then
                    if BenillaAddonListFrame and BenillaAddonListFrame:IsVisible() then
                        BenillaAddonListFrame:Hide()
                    elseif BenillaOptionsFrameCloseButton then
                        BenillaOptionsFrameCloseButton:Click()
                    end
                end
                return Ref_ToggleGameMenu(clicked)
            end
            if StaticPopup_EscapePressed() then
                return
            end
            if BenillaOptions_IsOpen() then
                if BenillaAddonListFrame and BenillaAddonListFrame:IsVisible() then
                    BenillaAddonListFrame:Hide()
                elseif BenillaOptionsFrameCloseButton then
                    BenillaOptionsFrameCloseButton:Click()
                end
                return
            end
            return Ref_ToggleGameMenu(clicked)
        end

        -- `MainMenuBarMicroButtons.lua:47-58`: only ever pushes the button, so the stock decision
        -- stands and ours adds our window. Guarded for a test kit that loads no micro buttons.
        function UpdateMicroButtons()
            if Ref_UpdateMicroButtons then
                Ref_UpdateMicroButtons()
            end
            if MainMenuMicroButton and BenillaOptions_IsOpen() then
                MainMenuMicroButton:SetButtonState("PUSHED", 1)
            end
        end

        -- ââ Benilla AddOn Manager Logic ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
        UIPanelWindows["BenillaAddonListFrame"] = { area = "center", pushable = 0, whileDead = 1 }
        table.insert(UISpecialFrames, "BenillaAddonListFrame")

        function BenillaAddonList_Show()
            if not BenillaAddonListFrame then return end
            ShowUIPanel(BenillaAddonListFrame)
            BenillaAddonList_Update()
        end

        function BenillaAddonList_Toggle()
            if not BenillaAddonListFrame then return end
            if BenillaAddonListFrame:IsVisible() then
                HideUIPanel(BenillaAddonListFrame)
            else
                BenillaAddonList_Show()
            end
        end

        SLASH_BENILLAADDONS1 = "/addons"
        SLASH_BENILLAADDONS2 = "/addon"
        SlashCmdList["BENILLAADDONS"] = function()
            BenillaAddonList_Toggle()
        end

        function BenillaAddonList_Update()
            if not BenillaAddonListFrame then return end
            local count = GetNumAddOns()
            if not BenillaAddonListFrame.offset then BenillaAddonListFrame.offset = 0 end
            local maxOffset = math.max(0, count - 14)
            if BenillaAddonListFrame.offset > maxOffset then
                BenillaAddonListFrame.offset = maxOffset
            end
            if BenillaAddonListFrame.offset < 0 then
                BenillaAddonListFrame.offset = 0
            end

            -- Force load checkbox
            local forceBox = getglobal("BenillaAddonListFrameForceLoad")
            if forceBox then
                local check = GetCVar("checkAddonVersion")
                forceBox:SetChecked(check == "0")
            end

            for i = 1, 14 do
                local row = getglobal("BenillaAddonListEntry" .. i)
                local idx = BenillaAddonListFrame.offset + i
                if row then
                    if idx <= count then
                        row.addonIndex = idx
                        local name, title, notes, enabled, loadable, reason, security = GetAddOnInfo(idx)
                        local check = getglobal(row:GetName() .. "Check")
                        local titleText = getglobal(row:GetName() .. "Title")
                        local statusText = getglobal(row:GetName() .. "Status")

                        check:SetChecked(enabled and enabled == 1)
                        titleText:SetText(title or name)

                        if loadable then
                            titleText:SetTextColor(1.0, 0.82, 0.0)
                        elseif enabled and reason ~= "DEP_DISABLED" then
                            titleText:SetTextColor(1.0, 0.2, 0.2)
                        else
                            titleText:SetTextColor(0.55, 0.55, 0.55)
                        end

                        if IsAddOnLoaded(idx) then
                            statusText:SetText("Loaded")
                            statusText:SetTextColor(0.2, 1.0, 0.2)
                        elseif IsAddOnLoadOnDemand(idx) then
                            statusText:SetText("On Demand")
                            statusText:SetTextColor(0.5, 0.8, 1.0)
                        elseif not enabled then
                            statusText:SetText("Disabled")
                            statusText:SetTextColor(0.5, 0.5, 0.5)
                        elseif reason then
                            statusText:SetText(getglobal("ADDON_" .. reason) or reason)
                            statusText:SetTextColor(1.0, 0.2, 0.2)
                        else
                            statusText:SetText("Enabled")
                            statusText:SetTextColor(1.0, 0.82, 0.0)
                        end

                        row:Show()
                    else
                        row.addonIndex = nil
                        row:Hide()
                    end
                end
            end

            local scrollBar = getglobal("BenillaAddonListScrollBar")
            if scrollBar then
                scrollBar:SetMinMaxValues(0, maxOffset)
                scrollBar:SetValue(BenillaAddonListFrame.offset)
                if maxOffset > 0 then
                    scrollBar:Show()
                else
                    scrollBar:Hide()
                end
            end
        end

        function BenillaAddonList_ApplyProfile(profile)
            local count = GetNumAddOns()
            for i = 1, count do
                local name = GetAddOnInfo(i)
                local shouldEnable = false
                if profile == "classicplus" then
                    shouldEnable = (name == "Questie" or name == "Cartographer" or name == "ClassicCastbars"
                        or name == "OmniCC" or name == "Bagnon" or name == "Aux" or name == "Postal" or name == "VoiceOver")
                elseif profile == "purist" then
                    shouldEnable = (name == "ClassicCastbars" or name == "OmniCC")
                elseif profile == "raider" then
                    shouldEnable = (name == "Questie" or name == "Cartographer" or name == "ClassicCastbars"
                        or name == "OmniCC" or name == "Bagnon" or name == "Aux" or name == "Postal"
                        or name == "VoiceOver" or name == "ClassicThreatMeter" or name == "LunaUnitFrames"
                        or name == "BigWigs" or name == "DPSMate" or name == "Clique" or name == "ItemRack")
                end
                if shouldEnable then
                    EnableAddOn(i)
                else
                    DisableAddOn(i)
                end
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
            BenillaAddonList_Update()
        end
    ]]></Script>

    <!-- Row Template for In-Game AddOns List -->
    <Frame name="BenillaAddonListEntryTemplate" virtual="true" hidden="true">
        <Size><AbsDimension x="470" y="22"/></Size>
        <Frames>
            <CheckButton name="$parentCheck" inherits="UICheckButtonTemplate">
                <Size><AbsDimension x="20" y="20"/></Size>
                <Anchors><Anchor point="LEFT"><Offset><AbsDimension x="2" y="0"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        local parent = this:GetParent()
                        if parent.addonIndex then
                            if this:GetChecked() then
                                EnableAddOn(parent.addonIndex)
                            else
                                DisableAddOn(parent.addonIndex)
                            end
                            BenillaAddonList_Update()
                        end
                    </OnClick>
                </Scripts>
            </CheckButton>
            <Button name="$parentHover">
                <Anchors>
                    <Anchor point="TOPLEFT" relativeTo="$parentCheck" relativePoint="TOPRIGHT"><Offset><AbsDimension x="4" y="0"/></Offset></Anchor>
                    <Anchor point="BOTTOMRIGHT"><Offset><AbsDimension x="0" y="0"/></Offset></Anchor>
                </Anchors>
                <Layers>
                    <Layer level="ARTWORK">
                        <FontString name="$parentTitle" inherits="GameFontNormal" justifyH="LEFT">
                            <Size><AbsDimension x="310" y="20"/></Size>
                            <Anchors><Anchor point="LEFT"><Offset><AbsDimension x="4" y="0"/></Offset></Anchor></Anchors>
                        </FontString>
                        <FontString name="$parentStatus" inherits="GameFontHighlightSmall" justifyH="RIGHT">
                            <Size><AbsDimension x="120" y="20"/></Size>
                            <Anchors><Anchor point="RIGHT"><Offset><AbsDimension x="-6" y="0"/></Offset></Anchor></Anchors>
                        </FontString>
                    </Layer>
                </Layers>
                <HighlightTexture file="Interface\Buttons\UI-Listbox-Highlight2" alphaMode="ADD"/>
                <Scripts>
                    <OnEnter>
                        local parent = this:GetParent()
                        if parent.addonIndex and parent.addonIndex &lt;= GetNumAddOns() then
                            local name, title, notes, enabled, loadable, reason, security = GetAddOnInfo(parent.addonIndex)
                            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                            GameTooltip:AddLine(title or name, 1, 0.82, 0)
                            if notes and notes ~= "" then
                                GameTooltip:AddLine(notes, 1, 1, 1, 1)
                            end
                            local author = GetAddOnMetadata(parent.addonIndex, "Author")
                            if author then
                                GameTooltip:AddDoubleLine("Author:", author, 0.7, 0.7, 0.7, 1, 1, 1)
                            end
                            local version = GetAddOnMetadata(parent.addonIndex, "Version")
                            if version then
                                GameTooltip:AddDoubleLine("Version:", version, 0.7, 0.7, 0.7, 1, 1, 1)
                            end
                            local deps = { GetAddOnDependencies(parent.addonIndex) }
                            if deps and table.getn(deps) &gt; 0 then
                                GameTooltip:AddLine("Dependencies: " .. table.concat(deps, ", "), 0.7, 0.7, 0.7, 1)
                            end
                            GameTooltip:Show()
                        end
                    </OnEnter>
                    <OnLeave>
                        GameTooltip:Hide()
                    </OnLeave>
                    <OnClick>
                        local check = getglobal(this:GetParent():GetName() .. "Check")
                        check:Click()
                    </OnClick>
                </Scripts>
            </Button>
        </Frames>
    </Frame>

    <!-- In-Game AddOns Manager Frame -->
    <Frame name="BenillaAddonListFrame" toplevel="true" frameStrata="DIALOG" movable="true" enableMouse="true" hidden="true" parent="UIParent">
        <Size><AbsDimension x="520" y="475"/></Size>
        <Anchors><Anchor point="CENTER"/></Anchors>
        <Backdrop bgFile="Interface\DialogFrame\UI-DialogBox-Background" edgeFile="Interface\DialogFrame\UI-DialogBox-Border" tile="true">
            <BackgroundInsets><AbsInset left="11" right="12" top="12" bottom="11"/></BackgroundInsets>
            <TileSize><AbsValue val="32"/></TileSize>
            <EdgeSize><AbsValue val="32"/></EdgeSize>
        </Backdrop>
        <Layers>
            <Layer level="ARTWORK">
                <Texture name="$parentHeader" file="Interface\DialogFrame\UI-DialogBox-Header">
                    <Size><AbsDimension x="256" y="64"/></Size>
                    <Anchors><Anchor point="TOP"><Offset><AbsDimension x="0" y="12"/></Offset></Anchor></Anchors>
                </Texture>
                <FontString inherits="GameFontNormal" text="AddOns">
                    <Anchors><Anchor point="TOP" relativeTo="$parentHeader"><Offset><AbsDimension x="0" y="-14"/></Offset></Anchor></Anchors>
                </FontString>
                <FontString name="$parentProfileLabel" inherits="GameFontNormalSmall" text="UI Profile:">
                    <Anchors><Anchor point="TOPLEFT"><Offset><AbsDimension x="24" y="-36"/></Offset></Anchor></Anchors>
                </FontString>
            </Layer>
        </Layers>
        <Frames>
            <!-- Close Button (X) -->
            <Button name="$parentCloseButton" inherits="UIPanelCloseButton">
                <Anchors><Anchor point="TOPRIGHT"><Offset><AbsDimension x="-6" y="-6"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        HideUIPanel(this:GetParent())
                    </OnClick>
                </Scripts>
            </Button>

            <!-- Profile Presets -->
            <Button name="$parentProfileClassic" inherits="UIPanelButtonTemplate" text="Classic+">
                <Size><AbsDimension x="72" y="20"/></Size>
                <Anchors><Anchor point="LEFT" relativeTo="$parentProfileLabel" relativePoint="RIGHT"><Offset><AbsDimension x="6" y="0"/></Offset></Anchor></Anchors>
                <Scripts><OnClick>BenillaAddonList_ApplyProfile("classicplus")</OnClick></Scripts>
            </Button>
            <Button name="$parentProfilePurist" inherits="UIPanelButtonTemplate" text="Purist">
                <Size><AbsDimension x="64" y="20"/></Size>
                <Anchors><Anchor point="LEFT" relativeTo="$parentProfileClassic" relativePoint="RIGHT"><Offset><AbsDimension x="4" y="0"/></Offset></Anchor></Anchors>
                <Scripts><OnClick>BenillaAddonList_ApplyProfile("purist")</OnClick></Scripts>
            </Button>
            <Button name="$parentProfileRaider" inherits="UIPanelButtonTemplate" text="Raider">
                <Size><AbsDimension x="64" y="20"/></Size>
                <Anchors><Anchor point="LEFT" relativeTo="$parentProfilePurist" relativePoint="RIGHT"><Offset><AbsDimension x="4" y="0"/></Offset></Anchor></Anchors>
                <Scripts><OnClick>BenillaAddonList_ApplyProfile("raider")</OnClick></Scripts>
            </Button>

            <!-- Force Out-of-Date Load -->
            <CheckButton name="$parentForceLoad" inherits="UICheckButtonTemplate">
                <Size><AbsDimension x="20" y="20"/></Size>
                <Anchors><Anchor point="TOPRIGHT"><Offset><AbsDimension x="-175" y="-34"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        if this:GetChecked() then
                            SetCVar("checkAddonVersion", "0")
                        else
                            SetCVar("checkAddonVersion", "1")
                        end
                        BenillaAddonList_Update()
                    </OnClick>
                </Scripts>
            </CheckButton>
            <Button name="$parentForceLoadLabel">
                <Size><AbsDimension x="150" y="20"/></Size>
                <Anchors><Anchor point="LEFT" relativeTo="$parentForceLoad" relativePoint="RIGHT"><Offset><AbsDimension x="4" y="0"/></Offset></Anchor></Anchors>
                <ButtonText text="Load out of date AddOns" inherits="GameFontNormalSmall"/>
                <Scripts>
                    <OnClick>
                        local cb = getglobal("BenillaAddonListFrameForceLoad")
                        cb:Click()
                    </OnClick>
                </Scripts>
            </Button>

            <!-- Addon Entries (14 rows) -->
            <Frame name="BenillaAddonListEntry1" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT"><Offset><AbsDimension x="24" y="-66"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry2" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry1" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry3" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry2" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry4" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry3" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry5" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry4" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry6" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry5" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry7" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry6" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry8" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry7" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry9" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry8" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry10" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry9" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry11" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry10" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry12" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry11" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry13" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry12" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>
            <Frame name="BenillaAddonListEntry14" inherits="BenillaAddonListEntryTemplate">
                <Anchors><Anchor point="TOPLEFT" relativeTo="BenillaAddonListEntry13" relativePoint="BOTTOMLEFT"><Offset><AbsDimension x="0" y="-3"/></Offset></Anchor></Anchors>
            </Frame>

            <!-- ScrollBar -->
            <Slider name="BenillaAddonListScrollBar" inherits="UIPanelScrollBarTemplate" hidden="true">
                <Anchors>
                    <Anchor point="TOPRIGHT"><Offset><AbsDimension x="-20" y="-82"/></Offset></Anchor>
                    <Anchor point="BOTTOMRIGHT"><Offset><AbsDimension x="-20" y="-48"/></Offset></Anchor>
                </Anchors>
                <Scripts>
                    <OnValueChanged>
                        local val = math.floor(arg1 + 0.5)
                        if val ~= BenillaAddonListFrame.offset then
                            BenillaAddonListFrame.offset = val
                            BenillaAddonList_Update()
                        end
                    </OnValueChanged>
                </Scripts>
            </Slider>

            <!-- Bottom Control Buttons -->
            <Button name="$parentDisableAll" inherits="UIPanelButtonTemplate" text="Disable All">
                <Size><AbsDimension x="100" y="24"/></Size>
                <Anchors><Anchor point="BOTTOMLEFT"><Offset><AbsDimension x="20" y="16"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        local count = GetNumAddOns()
                        for i = 1, count do
                            DisableAddOn(i)
                        end
                        PlaySound("igMainMenuOptionCheckBoxOff")
                        BenillaAddonList_Update()
                    </OnClick>
                </Scripts>
            </Button>
            <Button name="$parentEnableAll" inherits="UIPanelButtonTemplate" text="Enable All">
                <Size><AbsDimension x="100" y="24"/></Size>
                <Anchors><Anchor point="LEFT" relativeTo="$parentDisableAll" relativePoint="RIGHT"><Offset><AbsDimension x="6" y="0"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        local count = GetNumAddOns()
                        for i = 1, count do
                            EnableAddOn(i)
                        end
                        PlaySound("igMainMenuOptionCheckBoxOn")
                        BenillaAddonList_Update()
                    </OnClick>
                </Scripts>
            </Button>
            <Button name="$parentReload" inherits="UIPanelButtonTemplate" text="Reload UI">
                <Size><AbsDimension x="100" y="24"/></Size>
                <Anchors><Anchor point="LEFT" relativeTo="$parentEnableAll" relativePoint="RIGHT"><Offset><AbsDimension x="20" y="0"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        if SaveAddOns then SaveAddOns() end
                        ReloadUI()
                    </OnClick>
                </Scripts>
            </Button>
            <Button name="$parentOkay" inherits="UIPanelButtonTemplate" text="Okay">
                <Size><AbsDimension x="100" y="24"/></Size>
                <Anchors><Anchor point="BOTTOMRIGHT"><Offset><AbsDimension x="-20" y="16"/></Offset></Anchor></Anchors>
                <Scripts>
                    <OnClick>
                        if SaveAddOns then SaveAddOns() end
                        HideUIPanel(this:GetParent())
                    </OnClick>
                </Scripts>
            </Button>
        </Frames>
        <Scripts>
            <OnShow>
                BenillaAddonList_Update()
            </OnShow>
            <OnMouseWheel>
                local cur = BenillaAddonListFrame.offset or 0
                if arg1 &gt; 0 then
                    BenillaAddonListFrame.offset = math.max(0, cur - 1)
                else
                    local maxOffset = math.max(0, GetNumAddOns() - 14)
                    BenillaAddonListFrame.offset = math.min(maxOffset, cur + 1)
                end
                BenillaAddonList_Update()
            </OnMouseWheel>
        </Scripts>
    </Frame>
</Ui>
KeyBindingsPage.xml<Ui>
    <!--
        The options window's Keybindings page: templates and script; its rows live in
        OptionsFrame.xml, which loads after. Only commands the engine dispatches appear.
        Deviation: the layout is the era Settings panel's Keybindings page (collapsible category
        sections), because 1.12's settings screens are much worse to use. Capture follows 1.12's
        Blizzard_BindingUI: while a capsule is selected the window is keyboard-enabled, so the
        next key binds through its OnKeyDown, and a mouse 3/4/5 click o