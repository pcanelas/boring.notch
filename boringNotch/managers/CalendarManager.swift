//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?
    private var scheduledAlarmTimers: [String: DispatchWorkItem] = [:]
    private var pendingNotifications: [(event: EventModel, triggerTime: Date)] = []
    private var currentNotificationWorkItem: DispatchWorkItem?

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        currentNotificationWorkItem?.cancel()
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
                if Defaults[.calendarEventNotificationsEnabled] {
                    await self?.scheduleEventAlarms()
                }
                await self?.validateActiveCalendarEvent()
                await self?.checkForActiveEvent()
            }
        }
    }

    private func validateActiveCalendarEvent() async {
        guard let activeEventID = BoringViewCoordinator.shared.activeCalendarEvent.eventID else { return }

        // Check if the active event still exists
        guard let currentEvent = await calendarService.event(withIdentifier: activeEventID) else {
            // Event was deleted, clear the active event (will check for next automatically)
            BoringViewCoordinator.shared.clearActiveCalendarEvent()
            return
        }

        let now = Date()

        // If event has already ended, clear it (will check for next automatically)
        if currentEvent.end <= now {
            BoringViewCoordinator.shared.clearActiveCalendarEvent()
            return
        }

        // Event still exists, check if times have changed
        let activeEvent = BoringViewCoordinator.shared.activeCalendarEvent
        if currentEvent.start != activeEvent.eventStartTime || currentEvent.end != activeEvent.eventEndTime {
            // If event moved to the past (beyond grace period), clear it
            if currentEvent.end.addingTimeInterval(2.0) <= now {
                BoringViewCoordinator.shared.clearActiveCalendarEvent()
            } else {
                // Event times changed but still valid, update the active event
                let notificationTime = currentEvent.alarms.first?.triggerDate(for: currentEvent.start) ??
                                      currentEvent.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))

                // Only update if we're within the notification window
                if now >= notificationTime && currentEvent.end.addingTimeInterval(2.0) > now {
                    BoringViewCoordinator.shared.setActiveCalendarEvent(
                        eventID: currentEvent.id,
                        title: currentEvent.title,
                        startTime: currentEvent.start,
                        endTime: currentEvent.end,
                        notificationTime: notificationTime
                    )
                } else {
                    // Event moved but we're not in notification window anymore or it's too far in the past
                    BoringViewCoordinator.shared.clearActiveCalendarEvent()
                }
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            print("📅 Current calendar authorization status: \(status)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                events = await calendarService.events(
                    from: currentWeekStartDate,
                    to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                    calendars: selectedCalendars.map { $0.id })
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            events = await calendarService.events(
                from: currentWeekStartDate,
                to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                calendars: selectedCalendars.map { $0.id })
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            print("📅 Current reminder authorization status: \(status)")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        self.events = eventsResult
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        events = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: selectedCalendars.map { $0.id })
    }

    func startEventMonitoring() {
        guard Defaults[.calendarEventNotificationsEnabled] else { return }

        stopEventMonitoring()

        Task { @MainActor in
            await scheduleEventAlarms()
            await checkForActiveEvent()
        }
    }

    private func checkForActiveEvent() async {
        // Check if there's an event currently in progress or with active notification
        let now = Date()
        let endOfDay = Calendar.current.date(byAdding: .hour, value: 8, to: now)!

        let upcomingEvents = await calendarService.events(
            from: now.addingTimeInterval(-3600), // Look back 1 hour
            to: endOfDay,
            calendars: selectedCalendars.map { $0.id }
        )

        // Filter for events within their notification window
        let relevantEvents = upcomingEvents.filter { event in
            guard !event.isAllDay && event.end > now else { return false }

            // Calculate notification time
            let notificationTime = event.alarms.first?.triggerDate(for: event.start) ??
                                  event.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))

            // Only include if we're within notification window
            return now >= notificationTime
        }.sorted { $0.start < $1.start }

        // Activate the first relevant event if we don't have an active one
        if let firstEvent = relevantEvents.first,
           !BoringViewCoordinator.shared.activeCalendarEvent.isActive {
            let notificationTime = firstEvent.alarms.first?.triggerDate(for: firstEvent.start) ??
                                  firstEvent.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))

            BoringViewCoordinator.shared.setActiveCalendarEvent(
                eventID: firstEvent.id,
                title: firstEvent.title,
                startTime: firstEvent.start,
                endTime: firstEvent.end,
                notificationTime: notificationTime
            )
        }
    }

    func stopEventMonitoring() {
        for (_, task) in scheduledAlarmTimers {
            task.cancel()
        }
        scheduledAlarmTimers.removeAll()
        currentNotificationWorkItem?.cancel()
        currentNotificationWorkItem = nil
        pendingNotifications.removeAll()
    }

    func hasNextEventWaiting(excludingEventID: String?) -> Bool {
        let now = Date()

        return pendingNotifications.contains { notification in
            let event = notification.event
            // Check if this is a different event
            guard event.id != excludingEventID else { return false }
            // Event must not have ended
            guard event.end.addingTimeInterval(2.0) > now else { return false }
            // Calculate its notification time
            let notificationTime = event.alarms.first?.triggerDate(for: event.start) ??
                                  event.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))
            // Must be within notification window
            return now >= notificationTime
        }
    }

    func activateNextPendingEvent() {
        // Run all logic inside Task to prevent race conditions from multiple calls
        Task { @MainActor in
            let now = Date()

            // Find events that are upcoming or in progress and within notification window
            // Use stale data for initial filtering, but will re-fetch before activating
            let relevantEvents = pendingNotifications.filter { notification in
                let event = notification.event

                // Must not have ended (with grace period)
                guard event.end.addingTimeInterval(2.0) > now else { return false }

                // Calculate notification time
                let notificationTime = event.alarms.first?.triggerDate(for: event.start) ??
                                      event.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))

                // Only include if we're within notification window
                return now >= notificationTime
            }

            // Sort by start time to get the next chronological event
            guard let nextEvent = relevantEvents.sorted(by: { $0.event.start < $1.event.start }).first else {
                return
            }

            // CRITICAL: Re-fetch the event from EventKit to get current (non-stale) data
            // Events in pendingNotifications may have been modified since they were added
            guard let currentEvent = await calendarService.event(withIdentifier: nextEvent.event.id) else {
                // Event was deleted, remove and try next one
                pendingNotifications.removeAll { $0.event.id == nextEvent.event.id }
                activateNextPendingEvent()
                return
            }

            let nowRefreshed = Date()

            // Validate with current event data, not stale data
            guard currentEvent.end.addingTimeInterval(2.0) > nowRefreshed else {
                // Event has ended, remove and try next
                pendingNotifications.removeAll { $0.event.id == currentEvent.id }
                activateNextPendingEvent()
                return
            }

            // Calculate notification time with current event data
            let notificationTime = currentEvent.alarms.first?.triggerDate(for: currentEvent.start) ??
                                  currentEvent.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))

            // Only activate if we're within notification window
            guard nowRefreshed >= notificationTime else {
                // Not in notification window yet, don't activate
                return
            }

            // Activate with current (non-stale) event data
            BoringViewCoordinator.shared.setActiveCalendarEvent(
                eventID: currentEvent.id,
                title: currentEvent.title,
                startTime: currentEvent.start,
                endTime: currentEvent.end,
                notificationTime: notificationTime
            )
        }
    }

    private func scheduleEventAlarms() async {
        guard Defaults[.calendarEventNotificationsEnabled] else { return }

        let now = Date()
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        let upcomingEvents = await calendarService.events(
            from: now,
            to: endOfWeek,
            calendars: selectedCalendars.map { $0.id }
        )

        // Schedule notifications for each event's alarms
        for event in upcomingEvents {
            if event.isAllDay || event.start < now {
                continue
            }

            if case .reminder(let completed) = event.type, completed {
                continue
            }

            for alarm in event.alarms {
                guard let triggerDate = alarm.triggerDate(for: event.start) else { continue }

                // Only schedule if trigger is in the future
                guard triggerDate > now else { continue }

                let timeUntilTrigger = triggerDate.timeIntervalSince(now)
                let timerKey = "\(event.id)_\(triggerDate.timeIntervalSince1970)"

                let workItem = DispatchWorkItem { [weak self, timerKey, eventID = event.id, eventStart = event.start] in
                    Task { @MainActor [weak self, timerKey, eventID, eventStart] in
                        await self?.showEventNotificationIfValid(eventID: eventID, eventStart: eventStart, expectedTriggerDate: triggerDate)
                        self?.scheduledAlarmTimers.removeValue(forKey: timerKey)
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilTrigger, execute: workItem)
                scheduledAlarmTimers[timerKey] = workItem
            }
        }

        for event in upcomingEvents {
            if event.alarms.isEmpty && !event.isAllDay && event.start > now {
                if case .reminder(let completed) = event.type, completed {
                    continue
                }

                let notificationMinutes = TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60)
                let triggerDate = event.start.addingTimeInterval(-notificationMinutes)

                guard triggerDate > now else { continue }

                let timeUntilTrigger = triggerDate.timeIntervalSince(now)
                let timerKey = "\(event.id)_default"

                let workItem = DispatchWorkItem { [weak self, timerKey, eventID = event.id, eventStart = event.start] in
                    Task { @MainActor [weak self, timerKey, eventID, eventStart] in
                        await self?.showEventNotificationIfValid(eventID: eventID, eventStart: eventStart, expectedTriggerDate: triggerDate)
                        self?.scheduledAlarmTimers.removeValue(forKey: timerKey)
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilTrigger, execute: workItem)
                scheduledAlarmTimers[timerKey] = workItem
            }
        }
    }

    private func showEventNotificationIfValid(eventID: String, eventStart: Date, expectedTriggerDate: Date) async {
        guard Defaults[.calendarEventNotificationsEnabled] else { return }

        guard let currentEvent = await calendarService.event(withIdentifier: eventID) else {
            return
        }

        let alarmStillExists = currentEvent.alarms.contains { alarm in
            guard let triggerDate = alarm.triggerDate(for: eventStart) else { return false }
            return abs(triggerDate.timeIntervalSince(expectedTriggerDate)) < 1.0
        }

        let isDefaultNotification = currentEvent.alarms.isEmpty

        guard alarmStillExists || isDefaultNotification else {
            return
        }

        showEventNotification(for: currentEvent)
    }

    private func showEventNotification(for event: EventModel) {
        guard Defaults[.calendarEventNotificationsEnabled] else { return }

        let now = Date()

        if pendingNotifications.contains(where: { $0.event.id == event.id && $0.event.start == event.start }) {
            return
        }

        pendingNotifications.append((event: event, triggerTime: now))
        pendingNotifications.sort { $0.triggerTime < $1.triggerTime }

        if currentNotificationWorkItem == nil {
            processNextNotification()
        }
    }

    private func processNextNotification() {
        // Remove events that have already ended (with grace period for completion animation)
        let now = Date()
        pendingNotifications.removeAll { $0.event.end.addingTimeInterval(2.0) < now }

        guard !pendingNotifications.isEmpty else {
            currentNotificationWorkItem = nil
            return
        }

        // Find the first event that hasn't been shown yet
        guard let nextIndex = pendingNotifications.firstIndex(where: { now.timeIntervalSince($0.triggerTime) < 60 }) else {
            // All events were already shown, just wait
            currentNotificationWorkItem = nil
            return
        }

        let next = pendingNotifications[nextIndex]

        // Mark this event as shown by updating its trigger time
        pendingNotifications[nextIndex] = (event: next.event, triggerTime: Date.distantPast)

        // Play sound and show notification
        if let sound = NSSound(named: "Glass") {
            sound.play()
        }

        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .calendarEvent,
            duration: 8.0,
            eventTitle: next.event.title,
            eventStartTime: next.event.start
        )

        // Set the active calendar event for persistent tracking
        let coordinator = BoringViewCoordinator.shared
        let shouldReplace = !coordinator.activeCalendarEvent.isActive ||
                           next.event.start < coordinator.activeCalendarEvent.eventStartTime ||
                           Date() >= coordinator.activeCalendarEvent.eventEndTime

        if shouldReplace {
            // Calculate the notification time (when the alert was/will be triggered)
            let notificationTime = next.event.alarms.first?.triggerDate(for: next.event.start) ??
                                  next.event.start.addingTimeInterval(-TimeInterval(Defaults[.calendarEventNotificationMinutes] * 60))

            coordinator.setActiveCalendarEvent(
                eventID: next.event.id,
                title: next.event.title,
                startTime: next.event.start,
                endTime: next.event.end,
                notificationTime: notificationTime
            )
        }

        // Schedule next notification after 8 seconds
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Process next
            self.processNextNotification()
        }
        currentNotificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0, execute: workItem)
    }
}
