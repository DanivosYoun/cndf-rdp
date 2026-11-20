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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CNDFIronInputKind, CNDFIronPointerButton};

    fn wheel_flags(delta_x: i32, delta_y: i32) -> Vec<u16> {
        let event = CNDFIronInputEvent {
            kind: CNDFIronInputKind::CNDF_IRON_INPUT_WHEEL,
            code: 0,
            extended: false,
            pressed: false,
            button: CNDFIronPointerButton::CNDF_IRON_BUTTON_LEFT,
            x: 0,
            y: 0,
            delta_x,
            delta_y,
        };
        let Some(RdpInputEvent::FastPath(events)) = convert(&[event]) else {
            panic!("wheel input must become a fast-path batch");
        };
        events
            .iter()
            .map(|event| match event {
                FastPathInputEvent::MouseEvent(pdu) => {
                    let bytes = ironrdp_pdu::encode_vec(pdu).unwrap();
                    u16::from_le_bytes([bytes[0], bytes[1]])
                }
                _ => panic!("wheel input must be a mouse event"),
            })
            .collect()
    }

    // Same table as Tests/FreeRDPBridgeTests/ScrollSendResultTests.swift: both engines must put
    // the same 9-bit two's-complement wheel field on the wire for the same delta.
    #[test]
    fn wheel_delta_encodes_like_the_freerdp_bridge() {
        for (delta_y, delta_x, expected) in [
            (-1, 0, 0x03FF),
            (1, 0, 0x0201),
            (-120, 0, 0x0388),
            (120, 0, 0x0278),
            (-256, 0, 0x0300),
            (255, 0, 0x02FF),
            (-300, 0, 0x0300),
            (300, 0, 0x02FF),
            (i32::MIN, 0, 0x0300),
            (i32::MAX, 0, 0x02FF),
            (0, -1, 0x05FF),
            (0, 120, 0x0478),
            (0, -120, 0x0588),
        ] {
            assert_eq!(
                wheel_flags(delta_x, delta_y),
                vec![expected],
                "dy={delta_y} dx={delta_x}"
            );
        }
    }
}
