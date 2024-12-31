luanet.load_assembly("System");
luanet.load_assembly("log4net");

local Types = {};
Types["System.DateTime"] = luanet.import_type("System.DateTime");
Types["System.String"] = luanet.import_type("System.String");
Types["log4net.LogManager"] = luanet.import_type("log4net.LogManager");

local Settings = {};
Settings.BorrowingEnabled = nil;
Settings.LendingEnabled = nil;
Settings.BorrowingRenewalApprovedEmail = nil;
Settings.BorrowingRenewalApprovedEmailLibraryUse = nil;
Settings.BorrowingRenewalDeniedEmail = nil;
Settings.BorrowingRenewalDeniedEmailLibraryUse = nil;
Settings.BorrowingAllowFurtherRenewals = nil;
Settings.LendingRenewalDueDate = nil;
Settings.ActiveNvtgcs = {};
Settings.SharedServer = nil;

local isCurrentlyProcessing = false;

local rootLogger = "AtlasSystems.Addons.ILLiad.AutoRenewals";
local log = Types["log4net.LogManager"].GetLogger(rootLogger);

require("AtlasHelpers");

function Init()
	LoadSettings();
	RegisterSystemEventHandler("SystemTimerElapsed", "ProcessAutoRenewals");
end

function LoadSettings()
	Settings.BorrowingEnabled = GetSetting("BorrowingEnabled");
	Settings.LendingEnabled = GetSetting("LendingEnabled");
	Settings.BorrowingRenewalApprovedEmail = GetSetting("BorrowingRenewalApprovedEmail");
	Settings.BorrowingRenewalApprovedEmailLibraryUse = GetSetting("BorrowingRenewalApprovedEmailLibraryUse");
	Settings.BorrowingRenewalDeniedEmailLibraryUse = GetSetting("BorrowingRenewalDeniedEmailLibraryUse");
	Settings.BorrowingRenewalDeniedEmail = GetSetting("BorrowingRenewalDeniedEmail");
	Settings.BorrowingAllowFurtherRenewals = GetSetting("BorrowingAllowFurtherRenewals");
	
	--Load the lending due date setting and confirm it is a valid date. Use default value (nil) and log error message otherwise
	local dueDate = GetSetting("LendingRenewalDueDate");
	local dueDateValid, dueDateValue = pcall(function() 
												return Types["System.DateTime"].Parse(dueDate);
											 end);
	
	if (dueDateValid) then
		Settings.LendingRenewalDueDate = dueDateValue.Date;
		log:Debug("Successfully parsed LendingRenewalDueDate: " .. Settings.LendingRenewalDueDate:ToString());
	else
		log:Warn("Unable to parse LendingRenewalDueDate");
		Settings.LendingRenewalDueDate = nil;
	end
	
	local sharedServerSupport = GetCustomizationKeyValue("SharedServerSupport", "ILL");
	Settings.SharedServer = (string.lower(sharedServerSupport) == "yes");

	if (Settings.SharedServer) then
		local nvtgcString = GetSetting("NVTGC");
		
		if ((nvtgcString ~= nil) and (nvtgcString ~= "")) then
			nvtgcArray = AtlasHelpers.StringSplit(",",  nvtgcString);
			
			for _, nvtgc in ipairs(nvtgcArray) do
				nvtgc = string.upper(AtlasHelpers.Trim(nvtgc));
				
				if (nvtgc ~= "") then
					log:Debug("Adding active NVTGC: " .. nvtgc);
					Settings.ActiveNvtgcs[nvtgc] = nvtgc;
				end
			end
		end
	end
end

function ProcessAutoRenewals()
	if (not isCurrentlyProcessing) then
		isCurrentlyProcessing = true;
		
		local success = pcall(function() 
			if (Settings.BorrowingEnabled) then
				ProcessBorrowingAutoRenewals();
			end;
			
			if (Settings.LendingEnabled) then
				ProcessLendingAutoRenewals();
			end;
		end);

		if (success) then
			log:Info("Successfully processed renewals.");
		else
			log:Error("An error occurred while autorenewing user requests.");
			log:Error(error.Message or error);
		end
		
		isCurrentlyProcessing = false;
	else
		log:Debug("Renewals are still being processed.");
	end
end

function ProcessBorrowingAutoRenewals()
	log:Info("Processing Borrowing autorenewals");
	
	local success, error;
	
	success, error = pcall(function() ProcessDataContexts("TransactionStatus", "Renewal Requested", "HandleBorrowingRenewal") end);
	
	if (success) then
		success, error = pcall(function() ProcessDataContexts("TransactionStatus", "Renewed by Customer to%", "HandleBorrowingRenewal") end);
	end
	
	if (success) then
		success, error = pcall(function() ProcessDataContexts("TransactionStatus", "Renewed by ILL Staff to%", "HandleBorrowingRenewal") end);
	end

	if (success) then
		success, error = pcall(function() ProcessDataContexts("TransactionStatus", "Awaiting Renewal OK Processing", "HandleBorrowingRenewalApproval") end);
	end

	if (success) then
		success, error = pcall(function() ProcessDataContexts("TransactionStatus", "Awaiting Denied Renewal Processing", "HandleBorrowingRenewalDenial") end);
	end
	
	if (not success) then
		log:Error("An error occurred while autorenewing user requests.");
		log:Error(error.Message or error);
	else
		log:Info("Successfully processed Borrowing renewals");
	end
end

function ProcessLendingAutoRenewals()
	log:Info("Processing Lending autorenewals");
	local success, error = pcall(function() ProcessDataContexts("TransactionStatus","Awaiting Renewal Request Processing","ProcessLendingRenewal") end);
	if success then
		log:Info("Successfully processed Lending renewals");
	else
		log:Error("Error encountered while renewing Lending requests.");
		log:Error(error.Message or error);
	end
end

function ProcessLendingRenewal()
	local tn = GetFieldValue("Transaction","TransactionNumber");
	log:Debug("Handling lending renewal for transaction " .. tn);

	if string.lower(GetFieldValue("Transaction", "ProcessType")) ~= "lending" then
		log:Debug("Not a lending request.");
		return
	end

	local nvtgc = nil;
	if (Settings.SharedServer) then
		nvtgc = GetFieldValue("Transaction","Username");
	else
		nvtgc = "ILL";
	end
	log:Debug("NVTGC is ".. nvtgc);
	if (not ShouldHandleRequest(nvtgc)) then
		log:Debug("Addon not enabled for this NVTGC. Skipping processing.")
		return;
	end

	local systemId = GetFieldValue("Transaction","SystemID");

	local lendingRenewalPeriod = GetCustomizationKeyValue("LendingRenewalDateDays", nvtgc);
	if (lendingRenewalPeriod == nil) then
		log:Error("Unable to retrieve LendingRenewalDateDays custkey");
		return;
	else
		lendingRenewalPeriod = tonumber(lendingRenewalPeriod);
	end
	local standardDueDate = GetFieldValue("Transaction","DueDate"):AddDays(lendingRenewalPeriod);

	local dueDate = nil;
	-- If a due date was supplied, compare it to the standard due date and choose the later of the two.
	if (Settings.LendingRenewalDueDate) then
		log:Debug("Override due date is "..Settings.LendingRenewalDueDate:ToString());
		log:Debug("Standard due date is "..standardDueDate:ToString());
		local diff = Settings.LendingRenewalDueDate.Ticks - standardDueDate.Ticks;
		if diff < 0 then
			log:Debug("Normal renewal would be later than override date specified. Using normal renewal date: " .. standardDueDate:ToString());
			dueDate = standardDueDate;
		elseif diff >= 0 then
			log:Debug("Using override due date: " .. Settings.LendingRenewalDueDate:ToString());
			dueDate = Settings.LendingRenewalDueDate;
		end
	else
		-- Otherwise just use the standard due date.
		dueDate = standardDueDate;
	end

	SetFieldValue("Transaction", "DueDate", dueDate);

	log:Debug("Adding ESP Update.");
	RestrictedCommands:GrantRenewal(systemId, tn);

	ExecuteCommand("Route", {tn, "Renewed by ILL Staff to " .. dueDate:ToShortDateString()});
	ExecuteCommand("Route", {tn, "Item Shipped"});
	SaveDataSource("Transaction");
end

function GetCustomizationKeyValue(key, site)
	if key == nil then
		return nil;
	end
	local connection = CreateManagedDatabaseConnection();
	local success, value = pcall(function()
									connection.QueryString = "SELECT Value FROM Customization WHERE CustKey = '" .. key .. "'" .. " AND NVTGC = '" .. site .. "'";
									connection:Connect();
									return connection:ExecuteScalar();
  								 	end);
	connection:Dispose();

	if (not(success)) then
		log:Error("Error retrieving " .. key .. " from Customization.");
		return nil;
	else
		return value;
	end
end

function ShouldHandleRequest(userNvtgc)
	if (Settings.SharedServer) then
        log:Debug("Checking if the request should be processed for  NVTGC (" .. userNvtgc .. ")");
		--Assigning next to a throwaway local variable for lua efficiency reasons.
		local next = next;
		
		return ((next(Settings.ActiveNvtgcs) == nil) or (Settings.ActiveNvtgcs[AtlasHelpers.Trim(string.upper(userNvtgc))] ~= nil));
	else
		--Handle all requests because NVTGC is not configured
		return true;
	end
end

function HandleBorrowingRenewal()
	local tn = tonumber(GetFieldValue("Transaction", "TransactionNumber"));
	
	log:Debug("Handling borrowing renewal for transaction " .. tn);
	
	if not ShouldBorrowingRequestBeProcessed() then
		return;
	end

	--SystemID = OCLC
	local systemId = string.upper(GetFieldValue("Transaction", "SystemID"));
	
	if (systemId ~= "OCLC") then
		log:Debug("Transaction's SystemID (" .. systemId .. ") will not be processed.");
		return;
	end
	
	local illNumber = GetFieldValue("Transaction", "ILLNumber");
	
	if (illNumber == nil) or (illNumber == "") then
		log:Debug("Transaction's ILL Number is blank and will not be processed.");
		return;
	end

	log:Info("Renewing transaction " .. tn .. " and routing to 'Checked Out to Customer.'");
	RestrictedCommands:RequestRenewal(tn);
	ExecuteCommand("Route", {tn, "Checked Out to Customer"});
	
	RestrictedCommands:AddEventLogEntry("Renewals", "Renewals sent to table for OCLC updating.", "AutoRenewals Addon");
end

function HandleBorrowingRenewalApproval()
	if not ShouldBorrowingRequestBeProcessed() then
		return;
	end

	local transactionNumber = GetFieldValue("Transaction", "TransactionNumber");
	local libraryUseOnly = GetFieldValue("Transaction", "libraryUseOnly");
	local systemId = GetFieldValue("Transaction", "SystemID");

	log:Debug("Processing approved " .. systemId .. " renewal for transaction " .. transactionNumber .. ".");

	local connection = CreateManagedDatabaseConnection();

	local success, transactionDataOrErr = pcall(function()
		connection:Connect();

		local queryString = "SELECT TOP 1 Note, ChangedTo FROM Notes INNER JOIN Tracking ON Tracking.TransactionNumber = Notes.TransactionNumber WHERE Notes.TransactionNumber = '" .. transactionNumber .. "' AND (Note LIKE 'Renewal Due Date: %' OR Note LIKE 'Due Date updated to match RAPID due date of %') AND (ChangedTo = 'Checked Out to Customer' OR ChangedTo = 'Customer Notified via E-Mail') ORDER BY NoteDate, DateTime DESC";

		log:Debug("Querying the database with querystring: " .. queryString);

		connection.QueryString = queryString;
        local queryResults = connection:Execute();

		local transactionData = {};
		transactionData["note"] = queryResults.Rows:get_Item(0):get_Item("Note");
		transactionData["queueBeforeRenewal"] = queryResults.Rows:get_Item(0):get_Item("ChangedTo");

		return transactionData;
	end);

	connection:Dispose();

	if success then
		local newDueDate;
		local note = transactionDataOrErr["note"];

		-- Rapid renewals already have their due dates updated by the Rapid Manager.
		if systemId == "OCLC" then
			local year, month, day = note:match("Renewal Due Date: (%d%d%d%d)(%d%d)(%d%d)");
			newDueDate = month .. "/" .. day .. "/" .. year;

			SetFieldValue("Transaction", "DueDate", newDueDate);
		end
	
		
		if Settings.BorrowingAllowFurtherRenewals then
			SetFieldValue("Transaction", "RenewalsAllowed", true);
		end
	
		if libraryUseOnly then
			ExecuteCommand("SendTransactionNotification", {transactionNumber, Settings.BorrowingRenewalApprovedEmailLibraryUse});
		else
			ExecuteCommand("SendTransactionNotification", {transactionNumber, Settings.BorrowingRenewalApprovedEmail});
		end
	
		ExecuteCommand("Route", {transactionNumber, transactionDataOrErr["queueBeforeRenewal"]});
	
		SaveDataSource("Transaction");
	else
		log:Error("An error occurred when retrieving transaction info from the database: " .. tostring(TraverseError(transactionDataOrErr)));
	end
end

function HandleBorrowingRenewalDenial()
	if not ShouldBorrowingRequestBeProcessed() then
		return;
	end

	local transactionNumber = GetFieldValue("Transaction", "TransactionNumber");
	local systemId = GetFieldValue("Transaction", "SystemID");
	local libraryUseOnly = GetFieldValue("Transaction", "libraryUseOnly");

	log:Debug("Processing denied " .. systemId .. " renewal for transaction " .. transactionNumber .. ".");

	local connection = CreateManagedDatabaseConnection();

	local success, transactionDataOrErr = pcall(function()
		connection:Connect();

		local queryString;

		if systemId == "OCLC" then
			queryString = "SELECT TOP 1 Note, ChangedTo FROM Notes INNER JOIN Tracking ON Tracking.TransactionNumber = Notes.TransactionNumber WHERE Notes.TransactionNumber = '" .. transactionNumber .. "' AND Note LIKE 'Renewal Denied - Due Date: %' AND (ChangedTo = 'Checked Out to Customer' OR ChangedTo = 'Customer Notified via E-Mail') ORDER BY NoteDate, DateTime DESC";

		elseif systemId == "RAPID" then
			queryString = "SELECT TOP 1 ChangedTo FROM Tracking WHERE TransactionNumber = '" .. transactionNumber .. "' AND (ChangedTo = 'Checked Out to Customer' OR ChangedTo = 'Customer Notified via E-Mail') ORDER BY  DateTime DESC";
		else
			error("SystemID " .. systemId .. " renewals are not supported by the AutoRenewals addon.");
		end

		log:Debug("Querying the database with querystring: " .. queryString);

		connection.QueryString = queryString;
        local queryResults = connection:Execute();

		local transactionData = {};

		if systemId == "OCLC" then
			transactionData["note"] = queryResults.Rows:get_Item(0):get_Item("Note");
		end
		transactionData["queueBeforeRenewal"] = queryResults.Rows:get_Item(0):get_Item("ChangedTo");

		-- A bug prevents the original due date from being sent in the note when OCLC renewals are denied, so we can get the original due date from the history entry.
		if systemId == "OCLC" then
			queryString = "SELECT TOP 1 Entry FROM History WHERE TransactionNumber = " .. transactionNumber .. " AND Entry LIKE '%Original Due Date:%' ORDER BY DateTime DESC";
			log:Debug("Querying the database with querystring: " .. queryString);

			connection.QueryString = queryString;
			transactionData["originalDueDateEntry"] = connection:ExecuteScalar();
		end

		return transactionData;
	end);

	connection:Dispose();

	-- The Rapid Manager sets the due date for denied Rapid renewals, so we only have to set it for OCLC.
	local newDueDate;
	if systemId == "OCLC" then
		local year, month, day = transactionDataOrErr["note"]:match("Renewal Denied %- Due Date: (%d%d%d%d)(%d%d)(%d%d)");
		if year then
			newDueDate = month .. "/" .. day .. "/" .. year;
			log:Debug("Due date found in note.");

			SetFieldValue("Transaction", "DueDate", newDueDate);
		elseif transactionDataOrErr["originalDueDateEntry"] and transactionDataOrErr["originalDueDateEntry"]:find("%d+/%d+/%d%d%d%d") then
			newDueDate = transactionDataOrErr["originalDueDateEntry"]:match("%d+/%d+/%d%d%d%d");
			log:Debug("Due date not found in note. Using original due date from history entry.");

			SetFieldValue("Transaction", "DueDate", newDueDate);
		end

		if newDueDate then
			log:Debug("Updating due date for transaction " .. transactionNumber .. " to " .. newDueDate .. ".");
		else
			log:Warn("Due date not found in note or history entry. Due date for transaction " .. transactionNumber .. " will not be updated.");
		end
	end

	if success then
		if libraryUseOnly then
			ExecuteCommand("SendTransactionNotification", {transactionNumber, Settings.BorrowingRenewalDeniedEmailLibraryUse});
		else
			ExecuteCommand("SendTransactionNotification", {transactionNumber, Settings.BorrowingRenewalDeniedEmail});
		end

		ExecuteCommand("Route", {transactionNumber, transactionDataOrErr["queueBeforeRenewal"]});
		SaveDataSource("Transaction");
	else
		log:Error("An error occurred when retrieving transaction info from the database: " .. tostring(TraverseError(transactionDataOrErr)));
	end
end

function ShouldBorrowingRequestBeProcessed()
	--Confirm the request in context is appropriate to process
	if string.lower(GetFieldValue("Transaction", "ProcessType")) == "lending" then
		log:Debug("Not a borrowing request.");
		return false;
	end
	
	--User's nvtgc is in list of sites/delivery locations to process
	local userNvtgc = AtlasHelpers.Trim(string.upper(GetFieldValue("User", "NVTGC")));
	
	if (not ShouldHandleRequest(userNvtgc)) then
		log:Debug("User's NVTGC (" .. userNvtgc .. ") will not be processed.");
		return false;
	end

	return true;
end

function TraverseError(e)
    if not e.GetType then
        -- Not a .NET type
        return e;
    else
        if not e.Message then
            -- Not a .NET exception
            return e;
        end
    end

    log:Debug(e.Message);

    if e.InnerException then
        return TraverseError(e.InnerException);
    else
        return e.Message;
    end
end

function OnError(err)
    -- To ensure the addon doesn't get stuck in processing if it encounters an error.
    isCurrentlyProcessing = false;
    log:Error(tostring(TraverseError(err)));
end