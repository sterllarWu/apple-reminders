import EventKit
import Foundation

struct ReminderInput: Decodable {
    let title: String
    let due: String
    let place: String?
    let notes: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func parseDue(_ text: String) -> (DateComponents, Date) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.calendar = calendar
    let dayOnly = text.count == 10
    formatter.dateFormat = dayOnly ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
    guard let date = formatter.date(from: text) else {
        fail("无法解析时间 \(text)，需要 yyyy-MM-ddTHH:mm 或 yyyy-MM-dd")
    }
    var units: Set<Calendar.Component> = [.year, .month, .day]
    if !dayOnly { units.formUnion([.hour, .minute]) }
    var components = calendar.dateComponents(units, from: date)
    components.calendar = calendar
    components.timeZone = TimeZone.current
    let alarmDate: Date
    if dayOnly {
        var nine = calendar.dateComponents([.year, .month, .day], from: date)
        nine.hour = 9
        nine.minute = 0
        guard let made = calendar.date(from: nine) else { fail("无法生成当天 09:00 的提醒时间") }
        alarmDate = made
    } else {
        alarmDate = date
    }
    return (components, alarmDate)
}

// 输入走标准输入，全程不生成文件，失败时也没有中间产物需要清理
guard CommandLine.arguments.count == 1 else { fail("用法: swift WriteReminders.swift < 输入JSON") }
let data = FileHandle.standardInput.readDataToEndOfFile()
let items = try JSONDecoder().decode([ReminderInput].self, from: data)
guard !items.isEmpty else { fail("JSON 中没有提醒条目") }

// 写入前校验全部条目，避免出现写到一半才发现某条时间不合法
var plans: [(ReminderInput, DateComponents, Date)] = []
for item in items {
    guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("标题为空")
    }
    let (components, alarmDate) = parseDue(item.due)
    plans.append((item, components, alarmDate))
}

let store = EKEventStore()
// 首次运行会弹系统授权框，回调在用户点选之后返回
if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
    let wait = DispatchSemaphore(value: 0)
    store.requestFullAccessToReminders { _, _ in wait.signal() }
    if wait.wait(timeout: .now() + 180) == .timedOut { fail("等待提醒事项访问授权超时") }
}
guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
    fail("未获得完全访问权限，状态=\(EKEventStore.authorizationStatus(for: .reminder).rawValue)")
}
guard let list = store.defaultCalendarForNewReminders() else { fail("没有默认提醒事项清单") }

for (item, components, alarmDate) in plans {
    let reminder = EKReminder(eventStore: store)
    reminder.title = item.title
    reminder.calendar = list
    reminder.dueDateComponents = components
    let place = item.place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !place.isEmpty { reminder.location = place }
    var noteParts: [String] = []
    if let notes = item.notes, !notes.isEmpty { noteParts.append(notes) }
    if !place.isEmpty { noteParts.append("地点：\(place)") }
    reminder.notes = noteParts.isEmpty ? nil : noteParts.joined(separator: "\n")
    reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
    try store.save(reminder, commit: true)

    let id = reminder.calendarItemIdentifier
    guard let saved = store.calendarItem(withIdentifier: id) as? EKReminder else {
        fail("按标识 \(id) 未读回提醒")
    }
    guard saved.title == item.title else { fail("标题读回不一致：\(item.title)") }
    guard let savedDue = saved.dueDateComponents else { fail("到期时间读回为空：\(item.title)") }
    guard savedDue.year == components.year,
          savedDue.month == components.month,
          savedDue.day == components.day else { fail("到期日期读回不一致：\(item.title)") }
    if components.hour != nil {
        guard savedDue.hour == components.hour, savedDue.minute == components.minute else {
            fail("到期时刻读回不一致：\(item.title)")
        }
    }
    guard let alarms = saved.alarms, !alarms.isEmpty else { fail("提醒时间读回为空：\(item.title)") }
    if !place.isEmpty {
        guard let savedNotes = saved.notes, savedNotes.contains(place) else {
            fail("地点读回不一致：\(item.title)")
        }
    }
    print("OK\t\(item.title)\t\(item.due)\t\(place)\t\(list.title)\t\(id)")
}
print("DONE count=\(plans.count)")
