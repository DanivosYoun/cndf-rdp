use crate::{CNDFIronInputEvent, CNDFIronInputKind::*, CNDFIronPointerButton::*};
use ironrdp_client::rdp::RdpInputEvent;
use ironrdp_pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp_pdu::input::mouse::{MousePdu, PointerFlags};

pub(super) fn convert(events: &[CNDFIronInputEvent]) -> Option<RdpInputEvent> {
    let mut result = smallvec::SmallVec::new();
    for event in events {
        let key_flags = if event.pressed {
            KeyboardFlags::empty()
        } else {
            KeyboardFlags::RELEASE
        };
        let mouse = |flags, wheel| {
            FastPathInputEvent::MouseEvent(MousePdu {
                flags,
                number_of_wheel_rotation_units: wheel,
                x_position: event.x.min(u16::MAX.into()) as u16,
                y_position: event.y.min(u16::MAX.into()) as u16,
            })
        };
        match event.kind {
            CNDF_IRON_INPUT_KEY => {
                let flags = if event.extended {
                    key_flags | KeyboardFlags::EXTENDED
                } else {
                    key_flags
                };
                result.push(FastPathInputEvent::KeyboardEvent(
                    flags,
                    u8::try_from(event.code).ok()?,
                ));
            }
            CNDF_IRON_INPUT_UNICODE => result.push(FastPathInputEvent::UnicodeKeyboardEvent(
                key_flags, event.code,
            )),
            CNDF_IRON_INPUT_POINTER_MOVE => result.push(mouse(PointerFlags::MOVE, 0)),
            CNDF_IRON_INPUT_POINTER_BUTTON => {
                let mut flags = match event.button {
                    CNDF_IRON_BUTTON_LEFT => PointerFlags::LEFT_BUTTON,
                    CNDF_IRON_BUTTON_RIGHT => PointerFlags::RIGHT_BUTTON,
                    CNDF_IRON_BUTTON_MIDDLE => PointerFlags::MIDDLE_BUTTON_OR_WHEEL,
                };
                flags.set(PointerFlags::DOWN, event.pressed);
                result.push(mouse(flags, 0));
            }
            CNDF_IRON_INPUT_WHEEL => {
                for (delta, axis) in [
                    (event.delta_y, PointerFlags::VERTICAL_WHEEL),
                    (event.delta_x, PointerFlags::HORIZONTAL_WHEEL),
                ] {
                    if delta != 0 {
                        result.push(mouse(axis, delta.clamp(-256, 255) as i16));
                    }
                }
            }
        }
    }
    Some(RdpInputEvent::FastPath(result))
}
