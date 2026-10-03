"use client";

import { cn } from "~/lib/utils";
import React, { useRef, useState, useEffect } from "react";
import {
  motion,
  useMotionValue,
  useSpring,
  useTransform,
  animate,
  useVelocity,
  useAnimationControls,
} from "motion/react";
import { useIsMobile } from "~/hooks/use-mobile";

export const DraggableCardBody = ({
  className,
  children,
  style,
  onMouseDown,
}: {
  className?: string;
  children?: React.ReactNode;
  style?: React.CSSProperties;
  onMouseDown?: React.MouseEventHandler<HTMLDivElement>;
}) => {
  const isMobile = useIsMobile();
  const mouseX = useMotionValue(0);
  const mouseY = useMotionValue(0);
  const cardRef = useRef<HTMLDivElement>(null);
  const controls = useAnimationControls();
  const [constraints, setConstraints] = useState({
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
  });

  // physics biatch
  const velocityX = useVelocity(mouseX);
  const velocityY = useVelocity(mouseY);

  const springConfig = {
    stiffness: 100,
    damping: 20,
    mass: 0.5,
  };

  const rotateX = useSpring(
    useTransform(mouseY, [-300, 300], [25, -25]),
    springConfig,
  );
  const rotateY = useSpring(
    useTransform(mouseX, [-300, 300], [-25, 25]),
    springConfig,
  );

  const opacity = useSpring(
    useTransform(mouseX, [-300, 0, 300], [0.8, 1, 0.8]),
    springConfig,
  );

  const glareOpacity = useSpring(
    useTransform(mouseX, [-300, 0, 300], [0.2, 0, 0.2]),
    springConfig,
  );

  // 缓存卡片中心点：原来每次 mousemove 都调 getBoundingClientRect()，在大网格上
  // 会与 motion 的 transform 写入交错，每帧强制一次同步布局。
  const centerRef = useRef({ x: 0, y: 0 });

  useEffect(() => {
    // Update constraints when component mounts or its container resizes
    const updateConstraints = () => {
      const element = cardRef.current;
      if (typeof window !== "undefined" && element && element.offsetParent) {
        const { offsetLeft, offsetTop, offsetWidth, offsetHeight, offsetParent } = element;
        const parentRect = offsetParent.getBoundingClientRect();

        // Calculate the center point relative to the viewport
        const initialCenterX = parentRect.left + offsetLeft + offsetWidth / 2;
        const initialCenterY = parentRect.top + offsetTop + offsetHeight / 2;

        centerRef.current = { x: initialCenterX, y: initialCenterY };

        setConstraints({
          top: -initialCenterY,
          bottom: window.innerHeight - initialCenterY,
          left: -initialCenterX,
          right: window.innerWidth - initialCenterX,
        });
      }
    };

    updateConstraints();

    // 用 ResizeObserver 观察卡片容器，而不是监听 window resize。
    // 原实现是**每张卡片**一个 window resize 监听：N 张卡 = 一次 resize 触发 N 次
    // 布局读取（offsetLeft/offsetTop/... + getBoundingClientRect）与 N 次 setState。
    // ResizeObserver 只在容器尺寸真的变化时触发，且天然覆盖容器（不只是窗口）变化。
    const element = cardRef.current;
    const parent = (element?.offsetParent as HTMLElement | null) ?? null;
    let observer: ResizeObserver | undefined;

    if (typeof ResizeObserver !== "undefined" && parent) {
      observer = new ResizeObserver(updateConstraints);
      observer.observe(parent);
    } else {
      window.addEventListener("resize", updateConstraints);
    }

    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", updateConstraints);
    };
  }, []);

  const handleMouseMove = (e: React.MouseEvent<HTMLDivElement>) => {
    if (isMobile) return;
    const { clientX, clientY } = e;
    // 用缓存中心，不再每次事件都强制布局
    const { x: centerX, y: centerY } = centerRef.current;
    mouseX.set(clientX - centerX);
    mouseY.set(clientY - centerY);
  };

  const handleMouseLeave = () => {
    mouseX.set(0);
    mouseY.set(0);
  };

  return (
    <motion.div
      ref={cardRef}
      drag
      dragConstraints={constraints}
      onMouseDown={onMouseDown}
      onDragStart={() => {
        document.body.style.cursor = "grabbing";
      }}
      onDragEnd={(event, info) => {
        document.body.style.cursor = "default";

        controls.start({
          rotateX: 0,
          rotateY: 0,
          transition: {
            type: "spring",
            ...springConfig,
          },
        });
        const currentVelocityX = velocityX.get();
        const currentVelocityY = velocityY.get();

        const velocityMagnitude = Math.sqrt(
          currentVelocityX * currentVelocityX +
          currentVelocityY * currentVelocityY,
        );
        const bounce = Math.min(0.8, velocityMagnitude / 1000);

        animate(info.point.x, info.point.x + currentVelocityX * 0.3, {
          duration: 0.8,
          ease: [0.2, 0, 0, 1],
          bounce,
          type: "spring",
          stiffness: 50,
          damping: 15,
          mass: 0.8,
        });

        animate(info.point.y, info.point.y + currentVelocityY * 0.3, {
          duration: 0.8,
          ease: [0.2, 0, 0, 1],
          bounce,
          type: "spring",
          stiffness: 50,
          damping: 15,
          mass: 0.8,
        });
      }}
      style={{
        rotateX: isMobile ? 0 : rotateX,
        rotateY: isMobile ? 0 : rotateY,
        opacity: isMobile ? 1 : opacity,
        willChange: "transform",
        ...style,
      }}
      animate={controls}
      whileHover={isMobile ? undefined : { scale: 1.02 }}
      onMouseMove={isMobile ? undefined : handleMouseMove}
      onMouseLeave={isMobile ? undefined : handleMouseLeave}
      className={cn(
        "relative min-h-96 w-80 overflow-hidden rounded-md bg-neutral-100 p-6 shadow-2xl transform-3d dark:bg-neutral-900",
        className,
      )}
    >
      {children}
      {!isMobile && (
        <motion.div
          style={{
            opacity: glareOpacity,
          }}
          className="pointer-events-none absolute inset-0 bg-white select-none"
        />
      )}
    </motion.div>
  );
};

export const DraggableCardContainer = ({
  className,
  children,
}: {
  className?: string;
  children?: React.ReactNode;
}) => {
  return (
    <div className={cn("[perspective:3000px]", className)}>{children}</div>
  );
};
