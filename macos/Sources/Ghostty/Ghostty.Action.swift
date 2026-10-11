import SwiftUI
import GhosttyKit

extension Ghostty {
    struct Action {}
}

extension Ghostty.Action {
    struct ColorChange {
        let kind: Kind
        let color: Color

        enum Kind {
            case foreground
            case background
            case cursor
            case palette(index: UInt8)
        }

        init(c: ghostty_action_color_change_s) {
            switch c.kind {
            case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
                self.kind = .foreground
            case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
                self.kind = .background
            case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
                self.kind = .cursor
            default:
                self.kind = .palette(index: UInt8(c.kind.rawValue))
            }

            self.color = Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
    }

    struct MoveTab {
        let amount: Int

        init(c: ghostty_action_move_tab_s) {
            self.amount = c.amount
        }
    }

    struct OpenURL {
        enum Kind {
            case unknown
            case text
            case html
            case osc8

            init(_ c: ghostty_action_open_url_kind_e) {
                switch c {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
                    self = .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
                    self = .html
                case GHOSTTY_ACTION_OPEN_URL_KIND_OSC8:
                    self = .osc8
                default:
                    self = .unknown
                }
            }
        }

        let kind: Kind
        let url: String

        init(c: ghostty_action_open_url_s) {
            self.kind = Kind(c.kind)

            if let urlCString = c.url {
                let data = Data(bytes: urlCString, count: Int(c.len))
                self.url = String(data: data, encoding: .utf8) ?? ""
            } else {
                self.url = ""
            }
        }
    }

    struct ProgressReport {
        enum State {
            case remove
            case set
            case error
            case indeterminate
            case pause

            init(_ c: ghostty_action_progress_report_state_e) {
                switch c {
                case GHOSTTY_PROGRESS_STATE_REMOVE:
                    self = .remove
                case GHOSTTY_PROGRESS_STATE_SET:
                    self = .set
                case GHOSTTY_PROGRESS_STATE_ERROR:
                    self = .error
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
                    self = .indeterminate
                case GHOSTTY_PROGRESS_STATE_PAUSE:
                    self = .pause
                default:
                    self = .remove
                }
            }
        }

        let state: State
        let progress: UInt8?
    }

    /// What the programs in a surface report with the program status
    /// protocol (OSC 7501). The core picks the one record to show.
    struct ProgramStatus: Equatable {
        /// Ordered from least to most in need of the user.
        enum State: Int, Comparable {
            case idle
            case working
            case done
            case error
            case blocked

            init?(_ c: ghostty_action_program_status_state_e) {
                switch c {
                case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_IDLE: self = .idle
                case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING: self = .working
                case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_DONE: self = .done
                case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED: self = .blocked
                case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_ERROR: self = .error
                default: return nil
                }
            }

            static func < (lhs: State, rhs: State) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        /// What a blocked program needs from the user.
        enum Kind {
            case none
            case permission
            case question
            case auth

            init(_ c: UInt8) {
                switch ghostty_action_program_status_kind_e(rawValue: UInt32(c)) {
                case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION: self = .permission
                case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_QUESTION: self = .question
                case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_AUTH: self = .auth
                default: self = .none
                }
            }
        }

        let state: State
        let kind: Kind
        let progress: UInt8?

        /// The record's title or the program's name. May be empty. This is
        /// untrusted text from the program, so never treat it as markup.
        let label: String

        /// What the program is doing, waiting for, or has finished. May be
        /// empty. This is untrusted text from the program, so never treat it
        /// as markup.
        let msg: String

        /// Returns nil when there is no status to show.
        init?(c: ghostty_action_program_status_s) {
            guard let state = State(c.state) else { return nil }
            self.state = state
            self.kind = Kind(c.kind)
            self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
            self.label = String(cString: c.label)
            self.msg = String(cString: c.msg)
        }
    }

    struct Scrollbar {
        let total: UInt64
        let offset: UInt64
        let len: UInt64

        init(c: ghostty_action_scrollbar_s) {
            total = c.total
            offset = c.offset
            len = c.len
        }
    }

    struct StartSearch {
        let needle: String?

        init(c: ghostty_action_start_search_s) {
            if let needleCString = c.needle {
                self.needle = String(cString: needleCString)
            } else {
                self.needle = nil
            }
        }
    }

    enum PromptTitle {
        case surface
        case tab

        init(_ c: ghostty_action_prompt_title_e) {
            switch c {
            case GHOSTTY_PROMPT_TITLE_TAB:
                self = .tab
            default:
                self = .surface
            }
        }
    }

    enum KeyTable {
        case activate(name: String)
        case deactivate
        case deactivateAll

        init?(c: ghostty_action_key_table_s) {
            switch c.tag {
            case GHOSTTY_KEY_TABLE_ACTIVATE:
                let data = Data(bytes: c.value.activate.name, count: c.value.activate.len)
                let name = String(data: data, encoding: .utf8) ?? ""
                self = .activate(name: name)
            case GHOSTTY_KEY_TABLE_DEACTIVATE:
                self = .deactivate
            case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
                self = .deactivateAll
            default:
                return nil
            }
        }
    }
}

// Putting the initializer in an extension preserves the automatic one.
extension Ghostty.Action.ProgressReport {
    init(c: ghostty_action_progress_report_s) {
        self.state = State(c.state)
        self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
    }
}
